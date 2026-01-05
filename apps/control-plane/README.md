# Control Plane

Session management server for Netclode. Manages agent sandboxes via Kubernetes and provides WebSocket API for clients.

## Structure

```
apps/control-plane/
├── src/
│   ├── index.ts          # Entry point, HTTP/WebSocket server
│   ├── config.ts         # Configuration from environment
│   ├── api/
│   │   └── ws-server.ts  # WebSocket message handling
│   ├── sessions/
│   │   └── manager.ts    # Session lifecycle management
│   ├── runtime/
│   │   └── kubernetes.ts # Kubernetes/SandboxClaim integration
│   └── storage/
│       └── juicefs.ts    # JuiceFS workspace operations
├── Dockerfile
├── package.json
└── tsconfig.json
```

## Configuration

Environment variables (via k8s Secret):

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | HTTP server port | `3000` |
| `ANTHROPIC_API_KEY` | Anthropic API key | Required |
| `K8S_NAMESPACE` | Kubernetes namespace | `netclode` |
| `AGENT_IMAGE` | Agent container image | `ghcr.io/angristan/netclode-agent:latest` |

## Development

```bash
# Install dependencies
bun install

# Run in development
bun run dev

# Type check
bun run typecheck

# Build
bun run build
```

Note: Full functionality requires Kubernetes access. Use `kubectl port-forward` or run inside the cluster.

## API

### HTTP Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/ws` | GET | WebSocket upgrade |

### WebSocket Messages

Connect to `/ws` for real-time session management.

#### Client → Server

**Create Session**
```json
{
  "type": "session.create",
  "name": "my-project",
  "repo": "https://github.com/user/repo"
}
```

**List Sessions**
```json
{ "type": "session.list" }
```

**Resume Session**
```json
{ "type": "session.resume", "id": "abc123" }
```

**Pause Session**
```json
{ "type": "session.pause", "id": "abc123" }
```

**Delete Session**
```json
{ "type": "session.delete", "id": "abc123" }
```

**Send Prompt**
```json
{
  "type": "prompt",
  "sessionId": "abc123",
  "text": "Fix the bug in auth.ts"
}
```

**Interrupt Prompt**
```json
{ "type": "prompt.interrupt", "sessionId": "abc123" }
```

#### Server → Client

**Session Created**
```json
{
  "type": "session.created",
  "session": { "id": "abc123", "name": "my-project", "status": "ready", ... }
}
```

**Session List**
```json
{
  "type": "session.list",
  "sessions": [...]
}
```

**Agent Event**
```json
{
  "type": "agent.event",
  "sessionId": "abc123",
  "event": { "type": "tool_call", "tool": "Read", ... }
}
```

**Agent Done**
```json
{ "type": "agent.done", "sessionId": "abc123" }
```

**Error**
```json
{ "type": "error", "message": "Something went wrong" }
```

## Session Lifecycle

```
┌──────────┐     create      ┌──────────┐
│          │ ───────────────►│ creating │
│  (none)  │                 └────┬─────┘
│          │                      │
└──────────┘                      ▼
                            ┌──────────┐
       resume               │  ready   │◄────────┐
    ┌──────────────────────►└────┬─────┘         │
    │                            │               │
    │                            │ resume        │
    │                            ▼               │
    │                       ┌──────────┐         │
    │                       │ running  │─────────┘
    │                       └────┬─────┘  agent done
    │                            │
    │         pause              │
    │   ┌────────────────────────┘
    │   │
    │   ▼
┌───┴──────┐     delete     ┌──────────┐
│  paused  │ ──────────────►│ (deleted)│
└──────────┘                └──────────┘
```

## Kubernetes Integration

The control plane manages agent sandboxes via the Kubernetes API:

```typescript
// Create sandbox (SandboxClaim + PVC + Secret)
await k8s.createSandbox({
  sessionId: "abc123",
  cpus: 2,
  memoryMB: 2048,
});

// Wait for sandbox to be ready
const serviceFQDN = await k8s.waitForReady(sessionId);

// Delete sandbox
await k8s.deleteSandbox(sessionId);
```

Agent sandboxes run as Kata Container VMs via the `kata-clh` RuntimeClass.

## Storage Integration

Workspaces are stored on JuiceFS via PVCs:

```typescript
// Each session gets a PVC with JuiceFS StorageClass
// Workspace is mounted at /workspace in the agent pod
```

## Deployment

The control plane runs as a Kubernetes Deployment:

```bash
# View logs
kubectl logs -n netclode -l app=control-plane -f

# Restart
kubectl rollout restart deployment -n netclode control-plane

# Exec into pod
kubectl exec -it -n netclode deploy/control-plane -- sh
```

Container images are built via GitHub Actions and pushed to GHCR.

## Docker Build

```bash
# Build image
docker build -t netclode-control-plane -f Dockerfile ../..

# Run locally
docker run -p 3000:3000 \
  -e ANTHROPIC_API_KEY=sk-ant-xxx \
  netclode-control-plane
```
