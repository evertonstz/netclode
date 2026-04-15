# Terminal

Full interactive shell access to the sandbox.

## Overview

Each session has a PTY running inside the sandbox:

- Runs as `agent` user with passwordless sudo
- Starts in `/agent/workspace`
- Full color support (xterm-256color)
- Persists across app backgrounding

## Usage

**CLI:**
```bash
netclode shell                    # New sandbox + shell
netclode shell <session-id>       # Attach to existing
```
Ctrl+D exits. Ctrl+] detaches (session stays running).

**iOS App:** Tap terminal icon in bottom nav. Supports touch keyboard, copy/paste, pinch-to-zoom.

Terminal I/O flows through Connect streams: Client → Control Plane → Agent → node-pty → bash

## Environment

- `HOME=/agent`
- `SHELL=/bin/bash`
- `TERM=xterm-256color`
- `PATH` includes mise shims

```
/agent/                     # Home (persistent)
├── workspace/              # Your code
├── .local/share/mise/      # Installed tools
├── .cache/                 # Package caches
└── .claude/                # SDK session data
```

### Tools

```bash
mise use node@22            # Install runtimes via mise
docker compose up -d        # Docker available
sudo apt install htop       # Passwordless sudo
```

Tools persist across pause/resume (stored on the session's BoxLite QCOW2 disk).

## PTY Lifecycle

PTY spawns lazily on first terminal interaction. Survives app backgrounding and reconnection.

Destroyed on session pause/delete or shell exit. After resume, new PTY created on first interaction (shell history may be available from `.bash_history`).

When the PTY process exits (e.g., `exit` or Ctrl+D), the agent sends an OSC 9999 escape sequence (`\x1b]9999;pty-exit;<exitCode>\x07`) through the terminal output stream. The CLI shell client detects this and auto-detaches. Regular terminals ignore unknown OSC sequences, so this is invisible to the iOS app.

## Troubleshooting

**Terminal not connecting** - check session is ready/running, check control-plane logs:
```bash
kubectl --context netclode -n netclode logs -l app=control-plane | grep terminal
```

**No output after connecting** - try sending a keystroke (triggers PTY creation).

**Commands hang** - check network policy and DNS (`nslookup google.com`).
