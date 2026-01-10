# Control Plane

Go service that orchestrates Netclode. Manages sessions, proxies communication between clients and agents, persists state to Redis.

## What it does

- Session lifecycle (create, pause, resume, delete)
- Creates Sandbox CRDs, monitors readiness via k8s informers
- Bridges WebSocket clients to HTTP/SSE agents
- Stores sessions, messages, and events in Redis
- Real-time sync across clients via Redis Streams

## Architecture

```
services/control-plane/
├── cmd/control-plane/     # Entry point
└── internal/
    ├── api/               # HTTP/WebSocket server
    ├── session/           # Session manager
    ├── k8s/               # Kubernetes client (Sandbox CRDs)
    ├── storage/           # Redis persistence
    ├── protocol/          # Message types
    └── config/            # Configuration
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3000` | Server port |
| `K8S_NAMESPACE` | `netclode` | Kubernetes namespace |
| `AGENT_IMAGE` | `ghcr.io/angristan/netclode-agent:latest` | Agent image |
| `SANDBOX_TEMPLATE` | `netclode-agent` | SandboxTemplate name |
| `REDIS_URL` | `redis://redis-sessions...` | Redis URL |
| `WARM_POOL_ENABLED` | `false` | Use warm pool |
| `MAX_ACTIVE_SESSIONS` | `2` | Max concurrent sessions |
| `MAX_MESSAGES_PER_SESSION` | `1000` | Message history limit |
| `MAX_EVENTS_PER_SESSION` | `50` | Event history limit |

## WebSocket API

Connect to `/ws`. JSON messages.

### Client → Server

| Type | Fields | Description |
|------|--------|-------------|
| `session.create` | `name`, `repo?` | Create session |
| `session.list` | | List sessions |
| `session.open` | `id`, `lastNotificationId?` | Open with history |
| `session.resume` | `id` | Resume paused |
| `session.pause` | `id` | Pause |
| `session.delete` | `id` | Delete |
| `prompt` | `sessionId`, `text` | Send prompt |
| `prompt.interrupt` | `sessionId` | Interrupt |
| `port.expose` | `sessionId`, `port` | Expose port |
| `terminal.input` | `sessionId`, `data` | Terminal input |
| `terminal.resize` | `sessionId`, `cols`, `rows` | Resize terminal |
| `sync` | | Get all sessions |

### Server → Client

| Type | Description |
|------|-------------|
| `session.created` | Session created |
| `session.updated` | Status changed |
| `session.deleted` | Deleted |
| `session.list` | List of sessions |
| `session.state` | Session with history |
| `session.error` | Operation failed |
| `sync.response` | All sessions |
| `agent.message` | Text from agent (`partial` for streaming) |
| `agent.event` | Tool event |
| `agent.done` | Finished |
| `agent.error` | Error |
| `user.message` | User prompt (cross-client sync) |
| `port.exposed` | Port exposed with `previewUrl` |
| `terminal.output` | Terminal output |
| `error` | Generic error |

### Agent events

Delivered via `agent.event`:

| Kind | Description |
|------|-------------|
| `tool_start` | Tool started |
| `tool_input` | Input delta |
| `tool_end` | Tool completed |
| `file_change` | File created/edited/deleted |
| `command_start` | Shell command started |
| `command_end` | Shell command completed |
| `thinking` | Agent reasoning |
| `port_exposed` | Port exposed |

## HTTP

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Health check |
| `GET /ready` | Readiness check |

## Redis

| Key | Type | Description |
|-----|------|-------------|
| `sessions:all` | Set | All session IDs |
| `session:{id}` | Hash | Session metadata |
| `session:{id}:messages` | List | Conversation history |
| `session:{id}:events:stream` | Stream | Tool events |
| `session:{id}:notifications` | Stream | Real-time notifications |

### Why Redis Streams

The classic approach for real-time updates is: fetch history, then subscribe to pub/sub. Problem is there's a race condition. Events that happen between the history fetch and the subscription are lost.

Redis Streams solve this with cursor-based reading. Each entry in a stream has an ID (e.g., `1234567890123-0`). When a client opens a session:

1. Server returns current state + `lastNotificationId` (the latest stream ID)
2. Client stores this cursor
3. Server starts a blocking read with `XREAD BLOCK 0 STREAMS session:{id}:notifications {cursor}`
4. New events get pushed to the client as they arrive

On reconnect, the client sends its stored `lastNotificationId`. The server resumes from that position. Events that happened while disconnected are delivered immediately.

```
Client A connects
    │
    ▼
Server: XREAD BLOCK ... $  ($ = only new events)
    │
    ├──── Event 1 arrives ──► Client A receives
    ├──── Event 2 arrives ──► Client A receives
    │
Client A disconnects (cursor = "1234567890123-1")
    │
    ├──── Event 3 arrives ──► stored in stream
    ├──── Event 4 arrives ──► stored in stream
    │
Client A reconnects with cursor "1234567890123-1"
    │
    ▼
Server: XREAD BLOCK ... 1234567890123-1
    │
    ├──── Event 3 delivered immediately
    ├──── Event 4 delivered immediately
    └──── Resume blocking for new events
```

Multi-client sync works the same way. iOS app and web client on the same session both get events through separate XREAD consumers on the same stream.

The streams are trimmed to keep memory bounded (`MAXLEN ~50` for events, configurable via `MAX_EVENTS_PER_SESSION`).

## Data flow

```
┌─────────┐     WebSocket      ┌───────────────┐      HTTP/SSE      ┌─────────┐
│ Client  │◄──────────────────►│ Control Plane │◄──────────────────►│  Agent  │
└─────────┘                    └───────┬───────┘                    └─────────┘
                                       │
                                       ▼
                               ┌───────────────┐
                               │     Redis     │
                               └───────────────┘
```

1. Client sends prompt via WebSocket
2. Control plane persists to Redis, publishes to notifications stream
3. Control plane forwards to agent via HTTP
4. Agent streams SSE events back
5. Control plane persists and publishes to Redis Stream
6. All clients read via XREAD BLOCK

## Terminal proxy

The control plane proxies terminal I/O between clients and the agent's PTY:

```
Client                Control Plane              Agent
  │                        │                       │
  │ terminal.input ───────►│                       │
  │                        │ WS: {"type":"input"}─►│
  │                        │                       │ node-pty
  │                        │◄─ WS: {"type":"output"}│
  │◄─── terminal.output ───│                       │
```

The control plane maintains one WebSocket connection per active session to the agent's `/terminal/ws` endpoint. Multiple clients can connect to the same session and share the same PTY.

Terminal data is ephemeral (not persisted to Redis).

## Preview URLs

When a client sends `port.expose`, the control plane:

1. Creates a Tailscale Service for the sandbox pod (if not already created)
2. Waits for Tailscale to assign a MagicDNS hostname
3. Returns `port.exposed` with the preview URL

```
sandbox-{sessionId}.tailnet-name.ts.net:{port}
```

The sandbox pod gets its own Tailscale identity, so preview URLs are accessible from any device on your tailnet. Each sandbox can expose multiple ports on the same hostname.

## Session lifecycle

```
create → creating → running ↔ paused
              │         │        │
              └─────────┴────────┼──→ deleted
                   error ←───────┘
```

### Auto-pause

When `MAX_ACTIVE_SESSIONS` is reached and a new session needs to run, the control plane automatically pauses the oldest inactive session. "Inactive" means no prompt currently running.

Many paused sessions (cheap, just S3 storage), limited concurrent VMs (expensive, memory/CPU).

### Warm pool

When `WARM_POOL_ENABLED=true`, the control plane creates `SandboxClaim` resources instead of `Sandbox` resources directly. The agent-sandbox-controller assigns a pre-booted VM from the warm pool.

Pre-booted VMs are already running and have their JuiceFS PVC mounted, so session start is nearly instant (~1s vs ~30s cold start).

Since warm pool pods are created before we know which session they'll serve, they can't receive per-session env vars at boot. Instead, the agent calls `GET /internal/session-config?pod=<podName>` to fetch its configuration (session ID, API key, git repo) after startup.

## Development

```bash
go run ./cmd/control-plane
go test ./...
go build -o control-plane ./cmd/control-plane
```

## Docker

```bash
docker build -t control-plane -f Dockerfile .
```
