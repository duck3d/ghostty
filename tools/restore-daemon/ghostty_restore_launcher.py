#!/usr/bin/env python3
"""Ghostty Session Restore Launcher.

Reads session-restore.json and launches Claude sessions in Ghostty
using AppleScript. This is the "restore on startup" counterpart to
the daemon that writes the restore file.

This script is meant to be run after Ghostty starts (e.g., via a
login item or shell profile). It waits for Ghostty to be available,
then creates splits and injects resume commands.

Usage:
    uv run ghostty_restore_launcher.py [--restore-path PATH] [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path

log = logging.getLogger("ghostty-restore-launcher")


def wait_for_ghostty(timeout: int = 30) -> bool:
    """Wait for Ghostty to be running and responsive."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            result = subprocess.run(
                ["osascript", "-e", 'tell application "Ghostty" to get name'],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                return True
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
        time.sleep(1)
    return False


def get_terminal_count() -> int:
    """Get current number of terminals in front window."""
    try:
        result = subprocess.run(
            ["osascript", "-e",
             'tell application "Ghostty" to count terminals of front window'],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return int(result.stdout.strip())
    except (subprocess.TimeoutExpired, ValueError):
        pass
    return 0


def create_split_with_command(command: str, cwd: str | None = None) -> bool:
    """Create a new split and run a command in it."""
    # Build surface configuration
    config_parts = []
    if cwd:
        config_parts.append(f'initial working directory:"{cwd}"')
    config_parts.append(f'command:"{command}"')
    config_parts.append("wait after command:true")

    config_str = ", ".join(config_parts)

    script = f"""
    tell application "Ghostty"
        set cfg to new surface configuration from {{{config_str}}}
        tell front window
            set focusedTerm to focused terminal of selected tab
            split focusedTerm direction right with configuration cfg
        end tell
    end tell
    """
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            log.warning("Failed to create split: %s", result.stderr.strip())
            return False
        return True
    except subprocess.TimeoutExpired:
        log.warning("AppleScript timeout creating split")
        return False


def inject_command_in_focused(command: str) -> bool:
    """Type a command into the currently focused terminal (does NOT press enter)."""
    # Escape for AppleScript string
    escaped = command.replace("\\", "\\\\").replace('"', '\\"')

    script = f"""
    tell application "Ghostty"
        input text "{escaped}" to focused terminal of selected tab of front window
    end tell
    """
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False


def load_restore_file(path: Path) -> list[dict]:
    """Load and validate the restore file."""
    if not path.exists():
        log.info("No restore file found at %s", path)
        return []

    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as e:
        log.warning("Failed to read restore file: %s", e)
        return []

    if data.get("version") != 1:
        log.warning("Unsupported restore file version: %s", data.get("version"))
        return []

    return data.get("commands", [])


def restore_sessions(commands: list[dict], dry_run: bool = False) -> int:
    """Restore sessions by creating splits with resume commands.

    Returns the number of sessions successfully restored.
    """
    restored = 0

    for entry in commands:
        command = entry.get("command", "")
        if not command:
            continue

        if dry_run:
            log.info("[DRY RUN] Would restore: %s", command)
            restored += 1
            continue

        log.info("Restoring: %s", command)

        # For the first terminal, just inject the command
        if restored == 0:
            if inject_command_in_focused(command):
                restored += 1
            else:
                log.warning("Failed to inject command in first terminal")
        else:
            # Create a new split with the command
            if create_split_with_command(command):
                restored += 1
            else:
                log.warning("Failed to create split for: %s", command)

        # Brief pause between operations to let Ghostty settle
        if not dry_run:
            time.sleep(0.5)

    return restored


def main() -> None:
    parser = argparse.ArgumentParser(description="Ghostty Session Restore Launcher")
    parser.add_argument(
        "--restore-path",
        type=Path,
        default=None,
        help="Path to session-restore.json",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be restored without doing it",
    )
    parser.add_argument(
        "--no-wait",
        action="store_true",
        help="Don't wait for Ghostty to be available",
    )
    parser.add_argument(
        "--no-delete",
        action="store_true",
        help="Don't delete the restore file after consuming it",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable debug logging",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    restore_path = args.restore_path
    if restore_path is None:
        state_home = os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state"))
        restore_path = Path(state_home) / "ghostty" / "session-restore.json"

    # Load restore file
    commands = load_restore_file(restore_path)
    if not commands:
        log.info("Nothing to restore")
        return

    log.info("Found %d sessions to restore", len(commands))

    # Wait for Ghostty
    if not args.no_wait and not args.dry_run:
        log.info("Waiting for Ghostty...")
        if not wait_for_ghostty():
            log.error("Ghostty not available after 30s, aborting")
            sys.exit(1)
        # Extra pause for Ghostty to fully initialize
        time.sleep(2)

    # Restore
    restored = restore_sessions(commands, dry_run=args.dry_run)
    log.info("Restored %d/%d sessions", restored, len(commands))

    # Delete restore file (one-shot)
    if not args.dry_run and not args.no_delete and restore_path.exists():
        try:
            restore_path.unlink()
            log.info("Deleted restore file")
        except OSError as e:
            log.warning("Failed to delete restore file: %s", e)


if __name__ == "__main__":
    main()
