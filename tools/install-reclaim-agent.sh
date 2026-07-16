#!/usr/bin/env bash
#
# install-reclaim-agent.sh — (un)install the daily reclaim-disk LaunchAgent.
#
# Installs tools/launchd/com.thatcube.reclaim-disk.plist into
# ~/Library/LaunchAgents with its ProgramArguments path rewritten to THIS
# checkout's tools/reclaim-disk.sh, then (re)loads it so it runs daily at 03:30.
#
# USAGE
#   tools/install-reclaim-agent.sh            # install / update + load
#   tools/install-reclaim-agent.sh --uninstall
#   tools/install-reclaim-agent.sh --status
#
set -euo pipefail

LABEL="com.thatcube.reclaim-disk"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PLIST="$SELF_DIR/launchd/$LABEL.plist"
SCRIPT="$SELF_DIR/reclaim-disk.sh"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

action="${1:-install}"

load_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null \
    || launchctl load -w "$DEST"
}

case "$action" in
  --uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload "$DEST" 2>/dev/null || true
    rm -f "$DEST"
    echo "Uninstalled $LABEL."
    ;;
  --status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n '1,20p' \
      || echo "$LABEL is not loaded."
    ;;
  install|"")
    [ -f "$SRC_PLIST" ] || { echo "missing $SRC_PLIST" >&2; exit 1; }
    chmod +x "$SCRIPT" "$SELF_DIR/prune-deriveddata.sh" 2>/dev/null || true
    mkdir -p "$HOME/Library/LaunchAgents"
    # Rewrite the script path to this machine's checkout.
    sed "s#<string>/Users/brandon/Development/Plozz/tools/reclaim-disk.sh</string>#<string>$SCRIPT</string>#" \
      "$SRC_PLIST" > "$DEST"
    load_agent
    echo "Installed $LABEL -> $DEST"
    echo "Runs daily 03:30 via: $SCRIPT --days 4"
    echo "Log: ~/Library/Logs/reclaim-disk.log"
    ;;
  *) echo "usage: $0 [install|--uninstall|--status]" >&2; exit 1 ;;
esac
