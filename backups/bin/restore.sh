#!/usr/bin/env bash
# Restore a landscap3d dump into a target database.
# Refuses to touch the live 'landscap3d' DB without --force.
#
# Usage:
#   restore.sh <dump-file> <target-db> [--force]
# Examples:
#   restore.sh landscap3d-2026-04-22.dump landscap3d_scratch
#   restore.sh /path/to/some.dump landscap3d --force

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <dump-file> <target-db> [--force]" >&2
    exit 2
fi

DUMP="$1"
TARGET="$2"
FORCE="${3:-}"

# If not absolute and not in cwd, try dumps/ directory
if [[ "$DUMP" != /* ]] && [[ ! -f "$DUMP" ]]; then
    DUMP="$DUMPS_DIR/$DUMP"
fi
[[ -f "$DUMP" ]] || { echo "Dump file not found: $DUMP" >&2; exit 1; }

if [[ "$TARGET" == "$PG_DB" ]] && [[ "$FORCE" != "--force" ]]; then
    echo "Refusing to restore into live DB '$PG_DB' without --force" >&2
    exit 1
fi

echo "Restoring $DUMP → $TARGET"

docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -c \
    "CREATE DATABASE \"$TARGET\";" 2>/dev/null || \
    echo "  (database $TARGET already exists, restoring into it)"

docker exec -i "$PG_CONTAINER" \
    pg_restore -U "$PG_USER" --clean --if-exists -d "$TARGET" < "$DUMP"

echo "Done."
