#!/usr/bin/env bash
# Install the landscap3d backup LaunchAgent and add an ERROR-canary warning to ~/.zshrc.
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PLIST_SRC="$SCRIPT_DIR/com.landscap3d.backup.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.landscap3d.backup.plist"

# --- Install plist ---
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"
echo "Installed $PLIST_DST"

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "Loaded launchd job com.landscap3d.backup (fires daily at 03:15)"

# --- Add ERROR-canary warning to ~/.zshrc (idempotent via marker) ---
ZSHRC="$HOME/.zshrc"
MARKER="# landscap3d-backup-error-check"

if [[ -f "$ZSHRC" ]] && grep -qF "$MARKER" "$ZSHRC"; then
    echo "~/.zshrc already contains the backup-error check; leaving it alone"
else
    {
        echo ""
        echo "$MARKER"
        echo 'if [[ -f "$HOME/landscap3d-backups/ERROR" ]]; then'
        echo "    printf '\\033[1;31m⚠️  landscap3d backup FAILED — see ~/landscap3d-backups/ERROR\\033[0m\\n'"
        echo 'fi'
    } >> "$ZSHRC"
    echo "Appended backup-error check to $ZSHRC"
fi

echo ""
echo "Done. Open a new shell (or 'source ~/.zshrc') to activate the warning."
