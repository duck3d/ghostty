#!/usr/bin/env python3
"""Ghostty Session Restore Daemon.

Watches terminal sessions in Ghostty and maintains a restore file mapping
terminal panes to their restore commands (e.g., `claude --resume <id>`).

Until the Ghostty fork ships native session-state.json, this daemon uses
AppleScript to enumerate terminals and correlates PIDs to restore commands
via pluggable adapters.

Usage:
    uv run ghostty_restore.py [--interval 5] [--adapters-dir ~/.config/ghostty-restore/adapters]
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger("ghostty-restore")


# ─── Data Types ──────────────────────────────────────────────────────────────


@dataclass
class Terminal:
    """A terminal pane observed from Ghostty."""
    terminal_id: str
    name: str
    working_directory: str
    pid: int | None = None


@dataclass
class RestoreEntry:
    """A resolved restore command for a terminal."""
    terminal_id: str
    command: str


# ─── AppleScript Bridge ─────────────────────────────────────────────────────


def enumerate_terminals() -> list[Terminal]:
    """Use AppleScript to list all Ghostty terminals with metadata."""
    script = """
    tell application "Ghostty"
        set output to ""
        set termList to every terminal of front window
        repeat with t in termList
            set tid to id of t
            set tname to name of t
            set tcwd to working directory of t
            set output to output & tid & "\\t" & tname & "\\t" & tcwd & "\\n"
        end repeat
        return output
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
            log.warning("AppleScript failed: %s", result.stderr.strip())
            return []
    except (subprocess.TimeoutExpired, FileNotFoundError):
        log.warning("AppleScript not available")
        return []

    terminals = []
    for line in result.stdout.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) >= 3:
            terminals.append(Terminal(
                terminal_id=parts[0],
                name=parts[1],
                working_directory=parts[2],
            ))
    return terminals


def resolve_pids(terminals: list[Terminal]) -> None:
    """Resolve foreground PIDs for terminals by matching TTY devices.

    Ghostty doesn't expose PIDs via AppleScript, so we correlate by
    looking at `claude` processes and matching their session names to
    terminal titles.
    """
    # Get all claude processes with their PIDs and TTYs
    try:
        result = subprocess.run(
            ["ps", "-eo", "pid,command"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return

    claude_pids: list[int] = []
    for line in result.stdout.strip().split("\n"):
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].strip() in ("claude", "claude "):
            try:
                claude_pids.append(int(parts[0]))
            except ValueError:
                continue

    # Read Claude session files to build pid → session name mapping
    sessions_dir = Path.home() / ".claude" / "sessions"
    pid_to_name: dict[int, str] = {}
    for pid in claude_pids:
        session_file = sessions_dir / f"{pid}.json"
        if session_file.exists():
            try:
                data = json.loads(session_file.read_text())
                name = data.get("name", "")
                if name:
                    pid_to_name[pid] = name
            except (json.JSONDecodeError, OSError):
                continue

    # Match terminals to PIDs by session name in terminal title
    for terminal in terminals:
        for pid, name in pid_to_name.items():
            if name in terminal.name:
                terminal.pid = pid
                break


# ─── Adapter System ──────────────────────────────────────────────────────────


@dataclass
class AdapterResult:
    command: str


def run_builtin_claude_adapter(pid: int) -> AdapterResult | None:
    """Built-in Claude adapter: reads ~/.claude/sessions/{pid}.json."""
    session_file = Path.home() / ".claude" / "sessions" / f"{pid}.json"
    if not session_file.exists():
        return None
    try:
        data = json.loads(session_file.read_text())
        session_id = data.get("sessionId")
        if session_id:
            return AdapterResult(command=f"claude --resume {session_id}")
    except (json.JSONDecodeError, OSError):
        pass
    return None


def run_script_adapter(adapter_path: Path, pid: int, process_name: str) -> AdapterResult | None:
    """Run an external adapter script."""
    try:
        result = subprocess.run(
            [str(adapter_path), str(pid), process_name],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return AdapterResult(command=result.stdout.strip())
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError):
        pass
    return None


def resolve_restore_command(
    pid: int,
    process_name: str,
    adapters_dir: Path | None,
) -> str | None:
    """Try all adapters for a PID. Returns the restore command or None."""
    # Built-in Claude adapter first
    if process_name == "claude":
        result = run_builtin_claude_adapter(pid)
        if result:
            return result.command

    # External adapters
    if adapters_dir and adapters_dir.is_dir():
        for adapter in sorted(adapters_dir.iterdir()):
            if adapter.is_file() and os.access(adapter, os.X_OK):
                result = run_script_adapter(adapter, pid, process_name)
                if result:
                    return result.command

    return None


# ─── Restore File Writer ─────────────────────────────────────────────────────


def get_process_name(pid: int) -> str:
    """Get the process name for a PID."""
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "comm="],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            name = result.stdout.strip()
            # ps returns full path on some systems
            return os.path.basename(name)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return ""


@dataclass
class DaemonState:
    """Cached state to avoid redundant writes."""
    last_commands: dict[str, str] = field(default_factory=dict)


def write_restore_file(entries: list[RestoreEntry], path: Path) -> None:
    """Write session-restore.json atomically."""
    restore = {
        "version": 1,
        "commands": [
            {
                "terminal_id": e.terminal_id,
                "command": e.command,
            }
            for e in entries
        ],
    }

    # Atomic write: temp file + rename
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=".session-restore-",
        suffix=".tmp",
    )
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(restore, f, indent=2)
            f.write("\n")
        os.chmod(tmp_path, 0o600)
        os.rename(tmp_path, str(path))
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ─── Main Loop ───────────────────────────────────────────────────────────────


def run_once(
    adapters_dir: Path | None,
    restore_path: Path,
    state: DaemonState,
) -> None:
    """Single iteration of the daemon loop."""
    terminals = enumerate_terminals()
    if not terminals:
        return

    resolve_pids(terminals)

    entries: list[RestoreEntry] = []
    for terminal in terminals:
        if terminal.pid is None:
            continue

        process_name = get_process_name(terminal.pid)
        command = resolve_restore_command(terminal.pid, process_name, adapters_dir)
        if command:
            entries.append(RestoreEntry(
                terminal_id=terminal.terminal_id,
                command=command,
            ))

    # Check if anything changed
    current = {e.terminal_id: e.command for e in entries}
    if current == state.last_commands:
        return

    state.last_commands = current

    if entries:
        write_restore_file(entries, restore_path)
        log.info("Updated restore file: %d entries", len(entries))
    else:
        # No entries — remove stale file
        try:
            restore_path.unlink()
        except FileNotFoundError:
            pass


def main() -> None:
    parser = argparse.ArgumentParser(description="Ghostty Session Restore Daemon")
    parser.add_argument(
        "--interval",
        type=int,
        default=5,
        help="Poll interval in seconds (default: 5)",
    )
    parser.add_argument(
        "--adapters-dir",
        type=Path,
        default=Path.home() / ".config" / "ghostty-restore" / "adapters",
        help="Directory containing adapter scripts",
    )
    parser.add_argument(
        "--restore-path",
        type=Path,
        default=None,
        help="Path to write session-restore.json",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run once and exit (for testing)",
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
        # Default: XDG state dir
        state_home = os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state"))
        restore_path = Path(state_home) / "ghostty" / "session-restore.json"

    log.info("Ghostty restore daemon starting")
    log.info("Restore file: %s", restore_path)
    log.info("Adapters dir: %s", args.adapters_dir)
    log.info("Poll interval: %ds", args.interval)

    state = DaemonState()

    if args.once:
        run_once(args.adapters_dir, restore_path, state)
        return

    # Handle graceful shutdown
    running = True

    def handle_signal(signum: int, frame: object) -> None:
        nonlocal running
        log.info("Received signal %d, shutting down", signum)
        running = False

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    while running:
        try:
            run_once(args.adapters_dir, restore_path, state)
        except Exception:
            log.exception("Error in daemon loop")
        time.sleep(args.interval)

    log.info("Daemon stopped")


if __name__ == "__main__":
    main()
