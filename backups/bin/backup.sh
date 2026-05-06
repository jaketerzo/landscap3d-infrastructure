#!/usr/bin/env bash
# Daily Postgres backup for landscap3d with self-verification.
# Invoked by launchd at 03:15 AM; also runnable manually.
#
# Guarantees:
#   - A dump lands in dumps/ ONLY if it passes size, structural, and row-count checks.
#   - On failure: staging file is removed, dumps/ is untouched, ERROR canary is written.

set -euo pipefail

# launchd doesn't inherit interactive PATH — ensure docker is findable
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

mkdir -p "$DUMPS_DIR" "$LOGS_DIR"

TODAY=$(date '+%Y-%m-%d')
LOG_FILE="$LOGS_DIR/backup-$TODAY.log"

STAGING=""
VERIFY_DB=""
LOCK_HELD=0

cleanup() {
    local code=$?
    # Catch-all: any nonzero exit that didn't already write ERROR gets one here.
    # This guarantees the canary even for unguarded command failures under set -e.
    if [[ $code -ne 0 && ! -f "$ERROR_FILE" ]]; then
        {
            echo "Backup failed at $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Reason: script exited with code $code (unhandled error — see log)"
            echo "Log:    $LOG_FILE"
        } > "$ERROR_FILE"
    fi
    [[ -n "$STAGING" && -f "$STAGING" ]] && rm -f "$STAGING"
    if [[ -n "$VERIFY_DB" ]]; then
        docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -c \
            "DROP DATABASE IF EXISTS \"$VERIFY_DB\";" >/dev/null 2>&1 || true
    fi
    [[ $LOCK_HELD -eq 1 ]] && rmdir "$LOCK_DIR" 2>/dev/null || true
    exit $code
}
trap cleanup EXIT INT TERM

fail() {
    local reason="$1"
    log "FAILURE: $reason"
    {
        echo "Backup failed at $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Reason: $reason"
        echo "Log:    $LOG_FILE"
    } > "$ERROR_FILE"
    exit 1
}

# --- Lock (atomic mkdir) ---
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another backup run is already in progress (lock $LOCK_DIR); exiting"
    exit 0
fi
LOCK_HELD=1

log "=== Starting backup ==="

# --- Preflight ---
if ! command -v docker >/dev/null 2>&1; then
    fail "docker CLI not found in PATH"
fi
if ! docker info >/dev/null 2>&1; then
    fail "Docker daemon not reachable"
fi
if ! docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null | grep -q '^true$'; then
    fail "Container $PG_CONTAINER is not running"
fi

# --- Defensive cleanup: drop leftover verify DBs from prior failed runs ---
log "Cleaning up any stale landscap3d_verify_* databases..."
STALE_DBS=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -At -d postgres -c \
    "SELECT datname FROM pg_database WHERE datname LIKE 'landscap3d_verify_%';" 2>/dev/null || true)
if [[ -n "$STALE_DBS" ]]; then
    while IFS= read -r db; do
        log "  dropping stale verify DB: $db"
        docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -c \
            "DROP DATABASE IF EXISTS \"$db\";" >/dev/null
    done <<< "$STALE_DBS"
else
    log "  none found"
fi

# --- Dump to staging ---
STAGING="$BACKUP_ROOT/.staging-$$.dump"
FINAL="$DUMPS_DIR/landscap3d-$TODAY.dump"

log "Dumping $PG_DB to staging ($STAGING)..."
if ! docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc > "$STAGING"; then
    fail "pg_dump exited nonzero"
fi

# --- VERIFY 1: size ---
DUMP_SIZE=$(stat -f%z "$STAGING" 2>/dev/null || stat -c%s "$STAGING")
log "VERIFY 1/4: size = $DUMP_SIZE bytes"
if (( DUMP_SIZE < MIN_DUMP_BYTES )); then
    fail "dump size $DUMP_SIZE is below floor $MIN_DUMP_BYTES bytes"
fi

# --- VERIFY 2: TOC contains expected tables ---
log "VERIFY 2/4: pg_restore --list contains expected tables"
LIST_OUT=$(docker exec -i "$PG_CONTAINER" pg_restore --list < "$STAGING" 2>&1) \
    || fail "pg_restore --list failed on staged dump"
for tbl in "${EXPECTED_TABLES[@]}"; do
    if ! grep -qE "(TABLE DATA|TABLE)[^\"]* $tbl " <<< "$LIST_OUT"; then
        fail "expected table '$tbl' missing from dump table-of-contents"
    fi
    log "  $tbl present in TOC"
done

# --- VERIFY 3: smoke restore into temp DB ---
VERIFY_DB="landscap3d_verify_$$_$(date +%s)"
log "VERIFY 3/4: smoke restore into $VERIFY_DB"
docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -c \
    "CREATE DATABASE \"$VERIFY_DB\";" >/dev/null

# pg_restore can return nonzero on harmless warnings (missing roles, etc.).
# We trust the subsequent row-count check, not pg_restore's exit code.
docker exec -i "$PG_CONTAINER" \
    pg_restore -U "$PG_USER" -d "$VERIFY_DB" < "$STAGING" >/dev/null 2>&1 || \
    log "  pg_restore returned nonzero (often harmless); verifying via row counts"

# --- VERIFY 4: row counts ---
log "VERIFY 4/4: row counts in restored DB"
for tbl in "${EXPECTED_TABLES[@]}"; do
    cnt=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -At -d "$VERIFY_DB" -c \
          "SELECT COUNT(*) FROM \"$tbl\";" 2>/dev/null || true)
    if [[ -z "$cnt" ]]; then
        fail "could not count rows in '$tbl' after restore"
    fi
    if (( cnt <= 0 )); then
        fail "table '$tbl' has $cnt rows in verify DB (expected > 0)"
    fi
    log "  $tbl: $cnt rows"
done

# Verify DB no longer needed — drop explicitly (trap is belt-and-suspenders)
docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -c \
    "DROP DATABASE IF EXISTS \"$VERIFY_DB\";" >/dev/null
VERIFY_DB=""

# --- Promote staging → final (atomic rename within same FS) ---
log "Promoting staging → $FINAL"
mv "$STAGING" "$FINAL"
STAGING=""

echo "$(basename "$FINAL")" > "$LAST_GOOD_FILE"
rm -f "$ERROR_FILE"

# --- Prune old dumps + logs ---
pruned_dumps=$(find "$DUMPS_DIR" -name 'landscap3d-*.dump' -type f -mtime +$RETENTION_DAYS -print -delete | wc -l | tr -d ' ')
log "Pruned $pruned_dumps dump(s) older than $RETENTION_DAYS days"
pruned_logs=$(find "$LOGS_DIR" -name 'backup-*.log' -type f -mtime +$RETENTION_DAYS -print -delete | wc -l | tr -d ' ')
log "Pruned $pruned_logs log(s) older than $RETENTION_DAYS days"

# launchd.out / launchd.err are single append-only streams (not dated), so
# "prune by mtime" doesn't apply. Truncate in place when stale (>14d) or >1MB.
# Safe: launchd opens these O_APPEND; truncation just resets EOF to 0.
for f in "$LOGS_DIR/launchd.out" "$LOGS_DIR/launchd.err"; do
    [[ -f "$f" ]] || continue
    size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
    stale=$(find "$f" -mtime +$RETENTION_DAYS -print 2>/dev/null)
    if [[ -n "$stale" ]] || (( size > 1048576 )); then
        log "Truncating $(basename "$f") (was $size bytes)"
        : > "$f"
    fi
done

log "=== SUCCESS: $(basename "$FINAL") ($DUMP_SIZE bytes) ==="
