#!/usr/bin/env bash
# Shared config for landscap3d backup scripts. Sourced by backup.sh, restore.sh, install-launchd.sh.

BACKUP_ROOT="$HOME/landscap3d-backups"
BIN_DIR="$BACKUP_ROOT/bin"
DUMPS_DIR="$BACKUP_ROOT/dumps"
LOGS_DIR="$BACKUP_ROOT/logs"

PG_CONTAINER="landscap3d-postgres"
PG_DB="landscap3d"
PG_USER="landscap3d"

EXPECTED_TABLES=(species seasonal_palette species_monthly_keyframe species_growth_curve)

RETENTION_DAYS=14
MIN_DUMP_BYTES=10240

ERROR_FILE="$BACKUP_ROOT/ERROR"
LAST_GOOD_FILE="$BACKUP_ROOT/LAST_GOOD"
LOCK_DIR="$BACKUP_ROOT/.lock.d"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$msg" | tee -a "$LOG_FILE"
    else
        echo "$msg"
    fi
}
