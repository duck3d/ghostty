# Ghostty Session Restore

Restore terminal sessions (Claude Code, SSH, etc.) after a Ghostty restart.

## How It Works

```
┌─────────────────────┐     ┌──────────────────────┐     ┌──────────────────┐
│ Ghostty             │     │ Restore Daemon        │     │ Restore Launcher │
│                     │     │                       │     │                  │
│ Writes:             │────>│ Reads terminals via   │     │ Reads restore    │
│ session-state.json  │     │ AppleScript, resolves │     │ file, creates    │
│ (topology + PIDs)   │     │ PIDs to commands via  │────>│ splits via       │
│                     │     │ adapters              │     │ AppleScript      │
│ Reads:              │     │                       │     │                  │
│ session-restore.json│<────│ Writes:               │     │                  │
│ (resume commands)   │     │ session-restore.json   │     │                  │
└─────────────────────┘     └──────────────────────┘     └──────────────────┘
```

## Quick Start

```bash
# Install the daemon (runs in background via launchd)
./install.sh

# Test the daemon (one-shot, see what it finds)
python3 ghostty_restore.py --once --verbose

# Test the launcher (dry run, see what would be restored)
python3 ghostty_restore_launcher.py --dry-run
```

## Components

### `ghostty_restore.py` — Daemon

Polls Ghostty terminals, resolves PIDs to restore commands via adapters, writes `session-restore.json`.

```bash
# Run continuously (default: 5s interval)
python3 ghostty_restore.py

# One-shot mode
python3 ghostty_restore.py --once --verbose
```

### `ghostty_restore_launcher.py` — Launcher

Reads `session-restore.json` and creates Ghostty splits with resume commands.

```bash
# Restore sessions
python3 ghostty_restore_launcher.py

# Dry run
python3 ghostty_restore_launcher.py --dry-run
```

### `adapters/` — App Adapters

Each adapter resolves a PID to a restore command. Drop scripts into `~/.config/ghostty-restore/adapters/`.

**Interface:** `adapter.sh <pid> <process_name>` — print command on stdout, exit 0 to match.

Built-in: Claude Code adapter reads `~/.claude/sessions/{pid}.json`.

### `install.sh` — Service Installer

Installs the daemon as a macOS launchd user agent.

```bash
./install.sh           # Install and start
./install.sh uninstall # Stop and remove
```

## Files

| File | Owner | Location |
|------|-------|----------|
| `session-state.json` | Ghostty | `~/.local/state/ghostty/` |
| `session-restore.json` | Daemon | `~/.local/state/ghostty/` |
| Adapters | User | `~/.config/ghostty-restore/adapters/` |

## Security

- State files are written with `0600` permissions
- Restore commands are injected at the prompt but NOT auto-executed
- No IPC socket — communication is file-based only
- The restore file is deleted after consumption (one-shot)
