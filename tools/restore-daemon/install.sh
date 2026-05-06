#!/bin/bash
# Install the Ghostty Session Restore Daemon as a launchd user agent.
#
# Usage:
#   ./install.sh          # Install and start
#   ./install.sh uninstall # Stop and remove

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_SCRIPT="$SCRIPT_DIR/ghostty_restore.py"
LAUNCHER_SCRIPT="$SCRIPT_DIR/ghostty_restore_launcher.py"
PLIST_TEMPLATE="$SCRIPT_DIR/com.ghostty.restore-daemon.plist"
PLIST_NAME="com.ghostty.restore-daemon"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
LOG_DIR="$HOME/Library/Logs"
ADAPTERS_DIR="$HOME/.config/ghostty-restore/adapters"

# Find python3
PYTHON_PATH="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"

uninstall() {
    echo "Stopping daemon..."
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    rm -f "$PLIST_DEST"
    echo "Uninstalled."
}

install() {
    # Uninstall first if already installed
    if [ -f "$PLIST_DEST" ]; then
        echo "Existing installation found, removing..."
        uninstall
    fi

    # Create adapters directory
    mkdir -p "$ADAPTERS_DIR"

    # Copy Claude adapter if not already present
    if [ ! -f "$ADAPTERS_DIR/claude.sh" ]; then
        cp "$SCRIPT_DIR/adapters/claude.sh" "$ADAPTERS_DIR/claude.sh"
        chmod +x "$ADAPTERS_DIR/claude.sh"
        echo "Installed Claude adapter to $ADAPTERS_DIR/claude.sh"
    fi

    # Generate plist from template
    sed \
        -e "s|PYTHON_PATH|$PYTHON_PATH|g" \
        -e "s|DAEMON_PATH|$DAEMON_SCRIPT|g" \
        -e "s|LOG_DIR|$LOG_DIR|g" \
        "$PLIST_TEMPLATE" > "$PLIST_DEST"

    echo "Installed launchd plist to $PLIST_DEST"

    # Load the daemon
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
    echo "Daemon started."

    echo ""
    echo "The daemon is now running and will:"
    echo "  - Poll Ghostty terminals every 5 seconds"
    echo "  - Resolve Claude sessions to --resume commands"
    echo "  - Write session-restore.json to ~/.local/state/ghostty/"
    echo ""
    echo "To restore sessions after a restart, run:"
    echo "  python3 $LAUNCHER_SCRIPT"
    echo ""
    echo "Or add this to your shell profile for auto-restore:"
    echo "  # Ghostty session restore (add to ~/.zshrc)"
    echo "  if [ -f ~/.local/state/ghostty/session-restore.json ]; then"
    echo "    python3 $LAUNCHER_SCRIPT --no-wait &"
    echo "  fi"
    echo ""
    echo "To uninstall: $0 uninstall"
    echo "Logs: $LOG_DIR/ghostty-restore-daemon.log"
}

case "${1:-install}" in
    install)  install ;;
    uninstall) uninstall ;;
    *)
        echo "Usage: $0 [install|uninstall]"
        exit 1
        ;;
esac
