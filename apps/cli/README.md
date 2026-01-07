# Netclode CLI

Debug CLI client for the Netclode control plane. Useful for testing and debugging the WebSocket API.

## Usage

```bash
# Run with default local server
npm run dev --workspace=@netclode/cli

# Connect to a specific server
npm run dev --workspace=@netclode/cli -- --url ws://netclode.your-tailnet.ts.net/ws
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `-u, --url <url>` | Control plane WebSocket URL | `ws://localhost:3000/ws` |
| `-h, --help` | Show help | |

## Commands

Once connected, use these commands in the interactive REPL:

| Command | Description |
|---------|-------------|
| `create [name]` | Create a new session |
| `list` / `ls` | List all sessions |
| `resume <id>` | Resume a paused session |
| `pause <id>` | Pause a running session |
| `delete <id>` / `rm <id>` | Delete a session |
| `use <id>` | Set current session for prompts |
| `prompt <text>` / `p <text>` | Send prompt to current session |
| `prompt <id> <text>` | Send prompt to specific session |
| `interrupt [id]` / `stop [id]` | Interrupt current prompt |
| `quit` / `exit` / `q` | Exit the CLI |

## Example Session

```
$ npm run dev --workspace=@netclode/cli

Connecting to ws://localhost:3000/ws...
Connected!

Type 'help' for available commands.

netclode> create my-project
Creating session...

[SESSION CREATED] id=abc123 status=creating

netclode> use abc123
Switched to session abc123

netclode> p Fix the bug in auth.ts
Sending prompt...

[TOOL] Read: {"file_path":"/workspace/auth.ts"}...
[TOOL RESULT] import { verify } from...
[AGENT] I found the issue in auth.ts...

netclode> quit
Bye!
```
