#!/bin/bash
LOG=/tmp/deploy-setup.log
RC=/tmp/deploy-setup.rc
rm -f "$LOG" "$RC" 2>/dev/null || true
exec >"$LOG" 2>&1
echo "=== launcher: $(date) | $(whoami) ==="
bash /tmp/setup.sh
echo $? > "$RC"