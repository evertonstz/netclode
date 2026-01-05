# Netclode: Self-Hosted Claude Code Cloud

## Executive Summary

Building a self-hosted "Claude Code Cloud" - persistent sandboxed AI coding agents accessible from iOS/web, with full shell/Docker/network access, running on a single VPS with microVM isolation.

---

## Current Deployment Status

**Server**: DigitalOcean (161.35.214.216)
- 2 vCPU, 8GB RAM, 100GB SSD
- Debian 13 (trixie)
- k3s v1.34.3+k3s1 (single node)
- Cilium CNI v1.16.5
- KVM available (`/dev/kvm`) - Kata Containers supported

**Configuration**:
```
infra/ansible/
├── ansible.cfg
├── inventory/hosts.yml      # k3s_cluster format for k3s.orchestration
├── playbooks/site.yml       # imports k3s.orchestration.site
└── requirements.yml         # k3s.orchestration collection + artis3n.tailscale role
```

**Dependencies** (install with `ansible-galaxy install -r requirements.yml`):
- `k3s.orchestration` - Official k3s Ansible collection
- `artis3n.tailscale` - Tailscale role

---

## Part 1: Landscape Analysis

### Harness Options

| Option                           | Pros                                                    | Cons                                    |
| -------------------------------- | ------------------------------------------------------- | --------------------------------------- |
| **Claude Agent SDK**             | Official, full Claude Code capabilities, built-in tools (Read, Write, Edit, Bash, Glob, Grep, WebSearch, WebFetch), hooks, sessions, MCP support | Node.js/Python, newer                          |
| **Anthropic API + Custom Loop**  | Full control, any language                              | Build everything yourself               |
| **Claude Code CLI in Container** | Easiest, `--dangerously-skip-permissions`               | Process group bug with background tasks |

**Recommendation**: Claude Agent SDK (`@anthropic-ai/claude-agent-sdk` for TypeScript, `claude-agent-sdk` for Python) - it's the official way to run Claude Code programmatically and includes built-in tool execution, session management, and hooks.

### Sandbox Isolation Options

| Technology              | Boot Time           | Isolation        | Docker Inside          | Memory Overhead | Self-Host |
| ----------------------- | ------------------- | ---------------- | ---------------------- | --------------- | --------- |
| **Firecracker**         | <100ms (snapshots)  | Strong (microVM) | No (no device support) | ~5MB            | Yes       |
| **Kata Containers**     | 1-2s cold, <1s warm | Strong (VM)      | Yes                    | ~50MB           | Yes       |
| **gVisor**              | ~100ms              | Medium (syscall) | Limited                | Low             | Yes       |
| **Docker + bubblewrap** | Fast                | Weak             | Yes (DinD)             | Low             | Yes       |

**Recommendation**: Kata Containers with Firecracker backend - best balance of strong isolation AND Docker-inside support. Your existing Firecracker knowledge is directly applicable.

### Orchestration Options

| Option                       | Pros                                    | Cons                     |
| ---------------------------- | --------------------------------------- | ------------------------ |
| **agent-sandbox (k8s-sigs)** | Official k8s CRDs, WarmPool, Python SDK | Alpha (v0.1.0), Nov 2025 |
| **k3s + Kata + Custom CRDs** | Full control, proven stack              | More work                |
| **Plain Firecracker + Go**   | You've done this before                 | No k8s benefits          |
| **SkyPilot**                 | Session pooling, MCP integration        | Multi-cloud focused      |

**Recommendation**: Start with **agent-sandbox** on k3s - it's exactly what you described (SandboxTemplate, SandboxClaim, SandboxWarmPool) and is now a formal k8s-sigs project.

### Storage Options

| Option             | Pros                                   | Cons              |
| ------------------ | -------------------------------------- | ----------------- |
| **JuiceFS + S3**   | Scales independently, caching, k8s CSI | Complexity        |
| **Local PVCs**     | Simple, fast                           | Doesn't scale     |
| **hostPath + CoW** | Fastest, your Firecracker approach     | Manual management |

**Recommendation**: JuiceFS for the reasons you outlined - sessions can "sleep" (pods stopped) while storage persists cheaply on S3. Resume brings data back through transparent caching.

### Access/Tunnel Options

| Option                     | Pros                                   | Cons                 |
| -------------------------- | -------------------------------------- | -------------------- |
| **Tailscale K8s Operator** | Per-service hostnames, ACLs, magic DNS | Tailscale dependency |
| **Cloudflared**            | No account needed for tunnels          | Less integrated      |
| **Direct exposure**        | Simple                                 | Security             |

**Recommendation**: Tailscale K8s Operator - native per-session hostname exposure (`sess-<id>.tailnet`), ACLs restrict to your devices only.

---

## Part 2: Key Technical Decisions

### Why NOT just Docker/devcontainer?

1. **Background process bug** - Claude Code crashes (exit 137) when killing background processes in Docker due to shared process group
2. **Weaker isolation** - Container escapes are easier than VM escapes
3. **No nested Docker** - DinD is messy; Kata gives real Docker daemon inside VM

### Why NOT Copilot/Codex Cloud?

Your reasons are valid:

- PRs can't be deleted (trash on repos)
- Too slow for interaction
- Codex redacts terminal output on iOS
- Want your own credentials
- Want full TTY control

### Docker Inside MicroVMs

Kata Containers with the `kata-fc` (Firecracker) runtime class gives you:

- Real kernel inside (not syscall interception)
- Full Docker daemon per session
- `docker build`, `docker-compose`, etc.
- Network namespace isolation

### Session Lifecycle

```
┌─────────────────────────────────────────────────────────────────┐
│  Session States                                                  │
├─────────────────────────────────────────────────────────────────┤
│  [Created] → [Warm] → [Running] → [Paused] → [Archived]         │
│                ↑         ↓           ↓                           │
│           WarmPool    Active      Sleep                          │
│                      (Pod+PVC)   (PVC only)                      │
└─────────────────────────────────────────────────────────────────┘
```

- **Warm**: Pre-booted, waiting in pool
- **Running**: Active session with user
- **Paused**: Pod stopped, PVC retained, can resume
- **Archived**: Snapshot to S3, pod and hot cache removed

---

## Part 3: Architecture Design

### Single VPS Stack (Optimized for 16-32GB RAM)

```
┌─────────────────────────────────────────────────────────────────┐
│  VPS (~$20-40/mo, e.g., Hetzner CPX31/41, DigitalOcean)         │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  k3s cluster                                                ││
│  │  ├── Cilium CNI (NetworkPolicy enforcement)                 ││
│  │  ├── Kata Containers runtime (kata-fc)                      ││
│  │  ├── JuiceFS CSI driver                                     ││
│  │  ├── Tailscale Operator                                     ││
│  │  └── agent-sandbox controller                               ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  Control Plane (your app)                                   ││
│  │  ├── Session Manager API                                    ││
│  │  ├── Claude Agent SDK integration                           ││
│  │  ├── WebSocket server (PTY + events)                        ││
│  │  └── Web/iOS client                                         ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  Per-Session MicroVM (Kata + NixOS)                         ││
│  │  ├── /workspace → /juicefs/sessions/<id>/workspace          ││
│  │  ├── /nix/store → /juicefs/sessions/<id>/nix                ││
│  │  ├── dockerd (inside VM)                                    ││
│  │  ├── nix-shell for arbitrary deps                           ││
│  │  ├── Claude Agent process                                   ││
│  │  └── Background process manager                             ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

### Network Policy (Yolo But Not Stupid)

```yaml
# Per-session NetworkPolicy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: session-${ID}-egress
spec:
  podSelector:
    matchLabels:
      sandbox.agent.io/session: ${ID}
  policyTypes:
    - Egress
  egress:
    # Allow all internet
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8 # Block internal
              - 172.16.0.0/12 # Block internal
              - 192.168.0.0/16 # Block internal
              - 100.64.0.0/10 # Block Tailscale range
    # Allow DNS
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: 53
```

### Preview URLs via Tailscale

```yaml
# Per-session Service for web previews
apiVersion: v1
kind: Service
metadata:
  name: preview-${ID}
  annotations:
    tailscale.com/hostname: sess-${ID}
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    sandbox.agent.io/session: ${ID}
  ports:
    - port: 80
      targetPort: 8080 # Or detected from session
```

### Storage Architecture

**Single JuiceFS filesystem, subdirectories per session:**

```
/juicefs/                          # One filesystem, one S3 bucket
├── sessions/
│   ├── sess-abc123/
│   │   ├── workspace/             # Cloned repo, project files
│   │   └── nix/                   # Session's /nix/store
│   └── sess-def456/
│       ├── workspace/
│       └── nix/
└── metadata.db                    # JuiceFS metadata (Redis/SQLite)
```

**Why single filesystem:**
- Deduplication works - identical nix packages stored once in S3
- Simpler ops - one JuiceFS mount, one metadata DB
- Still isolated - each VM only mounts its own subdirectory

**Security:**
- VMs can't access other session dirs (not mounted, VM boundary enforced)
- Host mounts `/juicefs/sessions/sess-<id>/` into each VM, nothing else
- Kata VM = hardware isolation, can't escape to see parent dirs

### Rollback/Checkpoints

JuiceFS supports snapshots. After each significant agent turn:

```bash
juicefs snapshot /workspace/.snapshots/turn-${N}
```

Rollback = restore snapshot + recreate pod with same PVC.

---

## Part 4: Component Architecture

### Overall System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CLIENTS                                         │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐              │
│  │   iOS App       │  │   Web App       │  │   CLI (future)  │              │
│  │   (SwiftUI)     │  │   (React)       │  │                 │              │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘              │
│           │                    │                    │                        │
│           └────────────────────┼────────────────────┘                        │
│                                │ WebSocket                                   │
│                                ▼                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                         CONTROL PLANE (Bun)                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │   │
│  │  │ WebSocket   │  │ Session     │  │ k8s Client  │  │ Auth        │  │   │
│  │  │ Server      │  │ Manager     │  │ (CRDs)      │  │ (API keys)  │  │   │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └─────────────┘  │   │
│  │         │                │                │                           │   │
│  │         ▼                ▼                ▼                           │   │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │   │
│  │  │                    Message Router                                │ │   │
│  │  │  • Route prompts to correct session                             │ │   │
│  │  │  • Multiplex PTY streams                                        │ │   │
│  │  │  • Forward agent events to clients                              │ │   │
│  │  └─────────────────────────────────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                │                                             │
│                                │ kubectl exec / WebSocket                    │
│                                ▼                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                         KUBERNETES (k3s)                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  agent-sandbox controller                                            │    │
│  │  ├── SandboxTemplate (defines session config)                        │    │
│  │  ├── SandboxClaim (creates sessions)                                 │    │
│  │  └── SandboxWarmPool (pre-warmed sessions)                           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                │                                             │
│                                ▼                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Per-Session MicroVM (Kata + NixOS)                                  │    │
│  │  ┌─────────────────────────────────────────────────────────────┐    │    │
│  │  │  Agent Process (Bun + Claude Agent SDK)                      │    │    │
│  │  │  ├── Claude API client                                       │    │    │
│  │  │  ├── Tool executors (bash, file, etc.)                       │    │    │
│  │  │  └── Event emitter                                           │    │    │
│  │  ├─────────────────────────────────────────────────────────────┤    │    │
│  │  │  Services                                                    │    │    │
│  │  │  ├── dockerd (for container workloads)                       │    │    │
│  │  │  ├── Process supervisor (background tasks)                   │    │    │
│  │  │  └── Port monitor (dev server detection)                     │    │    │
│  │  ├─────────────────────────────────────────────────────────────┤    │    │
│  │  │  Storage (JuiceFS mounts)                                    │    │    │
│  │  │  ├── /workspace (project files)                              │    │    │
│  │  │  └── /nix/store (packages)                                   │    │    │
│  │  └─────────────────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Control Plane Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Control Plane (Bun/TypeScript)                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  apps/control-plane/src/                                                                        │
│  ├── index.ts                 # Entry point, starts servers                  │
│  ├── config.ts                # Environment, secrets                         │
│  │                                                                           │
│  ├── api/                     # HTTP/WebSocket handlers                      │
│  │   ├── ws-server.ts         # WebSocket connection handling                │
│  │   ├── routes/                                                             │
│  │   │   ├── sessions.ts      # CRUD for sessions                            │
│  │   │   └── health.ts        # Health checks                                │
│  │   └── middleware/                                                         │
│  │       └── auth.ts          # API key validation                           │
│  │                                                                           │
│  ├── sessions/                # Session lifecycle                            │
│  │   ├── manager.ts           # Create/list/delete sessions                  │
│  │   ├── state.ts             # In-memory session state                      │
│  │   └── types.ts             # Session interfaces                           │
│  │                                                                           │
│  ├── k8s/                     # Kubernetes integration                       │
│  │   ├── client.ts            # @kubernetes/client-node setup                │
│  │   ├── sandbox-claim.ts     # SandboxClaim CRUD                            │
│  │   ├── watcher.ts           # Watch for ready status                       │
│  │   └── types.ts             # CRD type definitions                         │
│  │                                                                           │
│  ├── streams/                 # Client ↔ Agent communication                 │
│  │   ├── pty.ts               # PTY stream handler (kubectl exec)            │
│  │   ├── events.ts            # Agent event forwarder                        │
│  │   └── protocol.ts          # WebSocket message types                      │
│  │                                                                           │
│  └── storage/                 # JuiceFS helpers                              │
│      ├── sessions.ts          # Create/delete session dirs                   │
│      └── snapshots.ts         # Checkpoint/rollback                          │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  Key Interfaces                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  interface Session {                                                         │
│    id: string;                                                               │
│    name: string;                                                             │
│    status: 'creating' | 'ready' | 'running' | 'paused' | 'error';           │
│    repo?: string;              // GitHub repo URL                            │
│    createdAt: Date;                                                          │
│    lastActiveAt: Date;                                                       │
│  }                                                                           │
│                                                                              │
│  // WebSocket messages (shared with clients)                                 │
│  type WSMessage =                                                            │
│    | { type: 'session.create'; repo?: string }                               │
│    | { type: 'session.list' }                                                │
│    | { type: 'session.resume'; id: string }                                  │
│    | { type: 'session.pause'; id: string }                                   │
│    | { type: 'prompt'; sessionId: string; text: string }                     │
│    | { type: 'terminal.input'; sessionId: string; data: string }             │
│    | { type: 'terminal.resize'; sessionId: string; cols: number; rows: number }│
│    | { type: 'terminal.output'; sessionId: string; data: string }            │
│    | { type: 'agent.event'; sessionId: string; event: AgentEvent }           │
│    | { type: 'agent.done'; sessionId: string }                               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Sandbox Agent Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Sandbox Agent (Bun + Claude Agent SDK)                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  apps/agent/src/                                                                      │
│  ├── index.ts                 # Entry point, SDK query() loop                │
│  ├── config.ts                # API keys from env, SDK options               │
│  │                                                                           │
│  ├── sdk/                     # Claude Agent SDK configuration               │
│  │   ├── options.ts           # ClaudeAgentOptions setup                     │
│  │   ├── hooks.ts             # PreToolUse, PostToolUse callbacks            │
│  │   └── agents.ts            # Custom subagent definitions (optional)       │
│  │                                                                           │
│  │   # NOTE: Built-in tools (Read, Write, Edit, Bash, Glob, Grep,            │
│  │   #       WebSearch, WebFetch) are provided by the SDK - no custom        │
│  │   #       implementations needed. Use `allowedTools` to control access.   │
│  │                                                                           │
│  ├── process/                 # Background process management                │
│  │   ├── supervisor.ts        # Track spawned processes                      │
│  │   ├── ports.ts             # Detect listening ports                       │
│  │   └── types.ts             # Process state interfaces                     │
│  │                                                                           │
│  ├── events/                  # Event emission to control plane              │
│  │   ├── stream.ts            # Forward SDK message stream                   │
│  │   └── types.ts             # Event type definitions                       │
│  │                                                                           │
│  └── ipc/                     # Communication with control plane             │
│      ├── stdin.ts             # Receive prompts via stdin                    │
│      └── stdout.ts            # Send responses/events via stdout             │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  SDK Usage Example                                                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  import { query, ClaudeAgentOptions, HookMatcher } from                      │
│    "@anthropic-ai/claude-agent-sdk";                                         │
│                                                                              │
│  // Audit logging via PostToolUse hook                                       │
│  const auditHook = async (input, toolUseId, context) => {                    │
│    emitEvent({ kind: "tool_call", tool: input.tool_name, ... });             │
│    return {};                                                                │
│  };                                                                          │
│                                                                              │
│  for await (const message of query({                                         │
│    prompt: userPrompt,                                                       │
│    options: {                                                                │
│      allowedTools: ["Read", "Write", "Edit", "Bash", "Glob", "Grep"],        │
│      permissionMode: "bypassPermissions",  // Sandbox handles isolation      │
│      hooks: {                                                                │
│        PostToolUse: [{ matcher: ".*", hooks: [auditHook] }]                  │
│      },                                                                      │
│      // Resume previous session                                              │
│      resume: sessionId  // Optional: continue from previous turn             │
│    }                                                                         │
│  })) {                                                                       │
│    forwardToControlPlane(message);                                           │
│  }                                                                           │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  Communication Protocol (stdin/stdout JSON lines)                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  // Control plane → Agent (stdin)                                            │
│  { "type": "prompt", "text": "Fix the bug in auth.ts", "sessionId": "..." }  │
│  { "type": "interrupt" }                                                     │
│  { "type": "shutdown" }                                                      │
│                                                                              │
│  // Agent → Control plane (stdout) - forwarded SDK messages                  │
│  { "type": "system", "subtype": "init", "session_id": "..." }                │
│  { "type": "assistant", "message": { "content": [...] } }                    │
│  { "type": "result", "result": "I've fixed the bug by..." }                  │
│                                                                              │
│  // PTY stream (separate channel via kubectl exec -it)                       │
│  Raw terminal I/O for interactive commands                                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### iOS App Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  iOS App (SwiftUI + iOS 26 Liquid Glass)                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  apps/ios/Netclode/                                                                   │
│  ├── App/                                                                    │
│  │   ├── NetclodeApp.swift          # App entry, scene setup                 │
│  │   └── AppState.swift             # Global app state (ObservableObject)    │
│  │                                                                           │
│  ├── Features/                                                               │
│  │   ├── Sessions/                  # Session management                     │
│  │   │   ├── SessionListView.swift  # List of sessions (glass cards)         │
│  │   │   ├── SessionRow.swift       # Individual session row                 │
│  │   │   ├── NewSessionSheet.swift  # Create session modal                   │
│  │   │   └── SessionViewModel.swift # Session list logic                     │
│  │   │                                                                       │
│  │   ├── Workspace/                 # Active session workspace               │
│  │   │   ├── WorkspaceView.swift    # Main workspace container               │
│  │   │   ├── ChatPanel.swift        # Prompt input + responses               │
│  │   │   ├── TerminalPanel.swift    # PTY terminal view                      │
│  │   │   ├── DiffPanel.swift        # File changes viewer                    │
│  │   │   └── WorkspaceVM.swift      # Workspace state                        │
│  │   │                                                                       │
│  │   └── Settings/                  # App settings                           │
│  │       ├── SettingsView.swift     # Server URL, theme, etc.                │
│  │       └── SettingsVM.swift                                                │
│  │                                                                           │
│  ├── Core/                                                                   │
│  │   ├── Network/                                                            │
│  │   │   ├── WebSocketClient.swift  # WebSocket connection                   │
│  │   │   ├── MessageHandler.swift   # Parse/route messages                   │
│  │   │   └── Reconnection.swift     # Auto-reconnect logic                   │
│  │   │                                                                       │
│  │   ├── Models/                                                             │
│  │   │   ├── Session.swift          # Session model                          │
│  │   │   ├── AgentEvent.swift       # Tool calls, file changes               │
│  │   │   └── Message.swift          # WebSocket message types                │
│  │   │                                                                       │
│  │   └── Services/                                                           │
│  │       ├── SessionService.swift   # Session CRUD                           │
│  │       ├── NotificationService.swift # Push notifications                  │
│  │       └── LiveActivityService.swift # Dynamic Island                      │
│  │                                                                           │
│  ├── UI/                            # Reusable components                    │
│  │   ├── Components/                                                         │
│  │   │   ├── GlassCard.swift        # Liquid glass card container            │
│  │   │   ├── GlassButton.swift      # Glass-styled button                    │
│  │   │   ├── TerminalView.swift     # Terminal emulator (xterm.js?)          │
│  │   │   └── MonacoView.swift       # Code viewer (WKWebView)                │
│  │   │                                                                       │
│  │   └── Styles/                                                             │
│  │       ├── GlassEffect.swift      # .glassEffect() modifier                │
│  │       ├── Theme.swift            # Colors, typography                     │
│  │       └── Animations.swift       # Fluid transitions                      │
│  │                                                                           │
│  └── Extensions/                                                             │
│      ├── LiveActivity/              # Live Activities for agent progress     │
│      │   ├── AgentActivityAttributes.swift                                   │
│      │   └── AgentActivityView.swift                                         │
│      └── Widget/                    # Home screen widget (optional)          │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  Key Views (Liquid Glass Design)                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  SessionListView:                                                            │
│  ┌──────────────────────────────────┐                                        │
│  │ ░░░░░░░░░░░ Sessions ░░░░░░░░░░░ │  ← Glass nav bar                       │
│  ├──────────────────────────────────┤                                        │
│  │ ┌────────────────────────────┐   │                                        │
│  │ │ ▫ my-project         ● ──▶│   │  ← Glass cards with blur               │
│  │ │   Active · 2 min ago      │   │                                        │
│  │ └────────────────────────────┘   │                                        │
│  │ ┌────────────────────────────┐   │                                        │
│  │ │ ▫ api-refactor       ○    │   │                                        │
│  │ │   Paused · 1 hour ago     │   │                                        │
│  │ └────────────────────────────┘   │                                        │
│  │                                  │                                        │
│  │         ┌─────────┐              │                                        │
│  │         │  + New  │              │  ← Floating glass button               │
│  │         └─────────┘              │                                        │
│  └──────────────────────────────────┘                                        │
│                                                                              │
│  WorkspaceView:                                                              │
│  ┌──────────────────────────────────┐                                        │
│  │ ← my-project          ⋯  ■      │  ← Glass nav                            │
│  ├──────────────────────────────────┤                                        │
│  │ ┌────────────────────────────┐   │                                        │
│  │ │ 🤖 Fixed the auth bug...  │   │  ← Chat messages                        │
│  │ │                            │   │                                        │
│  │ │ 📁 auth.ts (+12, -3)      │   │  ← File change events                   │
│  │ │                            │   │                                        │
│  │ └────────────────────────────┘   │                                        │
│  │ ┌────────────────────────────┐   │                                        │
│  │ │ $ npm test                │   │  ← Terminal panel (collapsible)        │
│  │ │ PASS src/auth.test.ts     │   │                                        │
│  │ └────────────────────────────┘   │                                        │
│  │ ┌────────────────────────────┐   │                                        │
│  │ │ Ask Claude...         ⬆  │   │  ← Input field (glass)                  │
│  │ └────────────────────────────┘   │                                        │
│  └──────────────────────────────────┘                                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Web App Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Web App (React + Vite)                                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  apps/web/                                                                        │
│  ├── src/                                                                    │
│  │   ├── main.tsx                   # Entry point                            │
│  │   ├── App.tsx                    # Root component, routing                │
│  │   │                                                                       │
│  │   ├── pages/                                                              │
│  │   │   ├── SessionsPage.tsx       # Session list                           │
│  │   │   └── WorkspacePage.tsx      # Active session                         │
│  │   │                                                                       │
│  │   ├── components/                                                         │
│  │   │   ├── SessionList.tsx                                                 │
│  │   │   ├── ChatPanel.tsx                                                   │
│  │   │   ├── Terminal.tsx           # xterm.js wrapper                       │
│  │   │   ├── DiffViewer.tsx         # Monaco diff editor                     │
│  │   │   └── PreviewFrame.tsx       # iframe for preview URLs                │
│  │   │                                                                       │
│  │   ├── hooks/                                                              │
│  │   │   ├── useWebSocket.ts        # WebSocket connection                   │
│  │   │   ├── useSessions.ts         # Session state                          │
│  │   │   └── useTerminal.ts         # Terminal state                         │
│  │   │                                                                       │
│  │   ├── stores/                    # Zustand stores                         │
│  │   │   ├── sessionStore.ts                                                 │
│  │   │   └── uiStore.ts                                                      │
│  │   │                                                                       │
│  │   └── lib/                                                                │
│  │       └── ws.ts                  # WebSocket client                       │
│  │                                                                           │
│  └── package.json                                                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Shared Protocol Package

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Shared Types (packages/protocol)                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  packages/protocol/                                                          │
│  ├── src/                                                                    │
│  │   ├── index.ts              # Re-exports all types                        │
│  │   ├── session.ts            # Session interface                           │
│  │   ├── messages.ts           # WebSocket message types (WSMessage union)   │
│  │   └── events.ts             # AgentEvent types                            │
│  ├── package.json              # { "name": "@netclode/protocol" }            │
│  └── tsconfig.json                                                           │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  Usage in other packages:                                                    │
│                                                                              │
│  // apps/control-plane/src/sessions/manager.ts                               │
│  import { Session, WSMessage } from "@netclode/protocol";                    │
│                                                                              │
│  // apps/web/src/hooks/useWebSocket.ts                                       │
│  import { WSMessage, AgentEvent } from "@netclode/protocol";                 │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 5: UX Design

### Two Streams Per Session

1. **PTY Stream** (WebSocket)

   - Full terminal emulation
   - Ctrl-C, resize, scrollback
   - Raw mode for interactive commands

2. **Agent Event Stream** (WebSocket/SSE)
   - Tool calls with metadata
   - File diffs
   - Git operations
   - Structured for UI rendering

### iOS/Web Client Features

- Session list (create, resume, archive)
- Chat panel (prompt input, interrupt)
- Terminal panel (full PTY)
- Diff viewer (file changes)
- Preview URLs (click to open)
- Notifications on agent turns
- "Autonomous plan mode" toggle

### iOS App Design

**Must be super nice liquid glass** - full iOS 26 design language:
- Glassmorphism throughout (translucent materials, depth, blur)
- Fluid animations and transitions
- Native SwiftUI with `.glassEffect()` modifiers
- Haptic feedback on interactions
- Dynamic Island integration for active sessions
- Live Activities for long-running agent tasks

### Background Process Management

Inside each session VM:

- Process supervisor (e.g., `overmind`, `hivemind`, or custom)
- Track: command, PID, status, ports
- Expose port mappings to control plane
- Auto-detect dev server ports (3000, 5173, 8000, etc.)

---

## Part 5: Implementation Phases

### Phase 1: Foundation

**1.1 VPS Requirements**
- Ubuntu 24.04 or Debian 12+ (we use Debian 13)
- 8GB+ RAM recommended for running multiple sandboxes
- KVM support for Kata Containers (check with `ls /dev/kvm`)

**1.2 Ansible Setup**

Install dependencies:
```bash
cd infra/ansible
ansible-galaxy install -r requirements.yml
```

Run playbook:
```bash
ansible-playbook playbooks/site.yml
```

The playbook configures:
- Base packages and locale
- Kernel modules (br_netfilter) and sysctl for k8s
- k3s via `k3s.orchestration` collection
- Tailscale (if `TAILSCALE_AUTHKEY` env var is set)

**1.3 k3s Configuration**

k3s is installed with these flags (see `inventory/hosts.yml`):
```yaml
extra_server_args: >-
  --disable=traefik
  --disable=servicelb
  --disable=local-storage
  --flannel-backend=none
  --disable-network-policy
```

We disable the built-in CNI and network policy because Cilium handles both.

**1.4 Cilium CNI**

Install manually after k3s is running:
```bash
cilium install --version 1.16.5
cilium status --wait
```

**Kata runtime options:**
| | kata-qemu | kata-fc | gVisor |
|---|-----------|---------|--------|
| Boot time | ~1-2s | ~125ms | ~100ms |
| Device support | Full | Limited | Limited |
| Docker inside | Yes | Yes | Limited |
| Requires KVM | Yes | Yes | **No** |
| Setup complexity | Easy | Needs devmapper | Easy |

### Phase 2: agent-sandbox

**2.1 Install agent-sandbox**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.1.0/manifest.yaml
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.1.0/extensions.yaml
kubectl get crd | grep sandbox
```

**2.2 SandboxTemplate**

Define a template with:
- Kata runtime (`runtimeClassName: kata-qemu`)
- Resource limits (CPU, memory per session)
- VolumeClaimTemplates for workspace + nix store
- NetworkPolicy (egress: allow internet, deny internal)
- Reference to NixOS sandbox image

**2.3 Sandbox Router**

The router bridges external clients to sandbox pods:
- Located in `clients/python/agentic-sandbox-client/sandbox-router/`
- Routes based on sandbox name to correct pod
- Expose via Tailscale or internal service

**2.4 SandboxWarmPool**

Configure a warm pool with 1-2 pre-warmed instances for fast allocation (<1s).

### Phase 3: Storage

**3.1 S3 Backend**

Create a bucket on Backblaze B2 or Cloudflare R2:
- R2 has free egress
- B2 is cheaper storage

**3.2 JuiceFS Setup**

Format filesystem (one-time):
```bash
juicefs format \
  --storage s3 \
  --bucket https://<bucket>.r2.cloudflarestorage.com \
  --access-key $ACCESS_KEY \
  --secret-key $SECRET_KEY \
  sqlite3:///var/lib/juicefs/meta.db \
  netclode
```

For single VPS, SQLite metadata is sufficient. Use Redis for multi-node.

**3.3 JuiceFS Systemd Service**

```ini
# /etc/systemd/system/juicefs.service
[Unit]
Description=JuiceFS mount
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/juicefs mount sqlite3:///var/lib/juicefs/meta.db /juicefs
ExecStop=/bin/umount /juicefs
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

**3.4 JuiceFS + agent-sandbox Integration**

Two options:

**Option A: JuiceFS CSI with subPath** - Install CSI driver, create StorageClass, CSI provisions subPaths within single filesystem. Deduplication works automatically.

**Option B: hostPath mounts (recommended to start)** - Skip CSI, use hostPath volumes in SandboxTemplate. Pre-create session dirs from control plane. Mount `/juicefs/sessions/<id>/workspace` as hostPath.

### Phase 4: Nix Binary Cache

**4.1 Install Nix and nix-serve on host**

```bash
# Install Nix
curl -L https://nixos.org/nix/install | sh -s -- --daemon

# Generate signing key
mkdir -p /var/secrets
nix-store --generate-binary-cache-key netclode-cache \
  /var/secrets/cache-priv.pem /var/secrets/cache-pub.pem

# Install nix-serve
nix-env -iA nixpkgs.nix-serve
```

**4.2 nix-serve Systemd Service**

```ini
# /etc/systemd/system/nix-serve.service
[Unit]
Description=Nix Binary Cache Server
After=network.target

[Service]
Type=simple
ExecStart=/nix/var/nix/profiles/default/bin/nix-serve \
  --port 5000 \
  --secret-key-file /var/secrets/cache-priv.pem
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

**4.3 Cache Security**

- Firewall restricts port 5000 to pod network (10.42.0.0/16)
- nix-serve is read-only (VMs can't poison host cache)
- All packages signed with host key

**4.4 Pre-warm Cache (optional)**

```bash
nix-shell -p nodejs php82 python311 go_1_23 rustc
```

### Phase 5: Sandbox VM Image

**5.1 NixOS Sandbox Image**

Create a flake for sandbox VM with:
- Minimal config: systemd, Docker, git, gh, Bun
- nix.conf configured to use host binary cache
- Agent entrypoint (Bun + Claude Agent SDK)
- Mounts for /workspace and /nix from host

```nix
nix.settings = {
  substituters = [ "http://10.0.0.1:5000" "https://cache.nixos.org" ];
  trusted-public-keys = [ "host-cache:xxxx" "cache.nixos.org-1:xxxx" ];
  require-sigs = true;
};
```

Build with `nixos-generate -f raw` for Kata.

### Phase 6: Agent Integration

**6.1 Control Plane Service**

Bun/TypeScript service that:
- Uses `@kubernetes/client-node` to manage SandboxClaim CRDs
- Creates SandboxClaim, watches for ready, provisions session subdirs
- WebSocket server for client connections
- Manages SDK session IDs for multi-turn conversations

**6.2 Sandbox Agent**

Bun + `@anthropic-ai/claude-agent-sdk` running inside sandbox VM:
- Control plane connects via kubectl exec / WebSocket
- Anthropic API key injected as env var (k8s secret)
- SDK options: `allowedTools`, `permissionMode: "bypassPermissions"`, `hooks`, `resume`

**6.3 PTY Streaming**

WebSocket server on control plane connecting to pod via `kubectl exec`. Handles resize, Ctrl-C, raw mode, stores scrollback.

**6.4 Event Streaming**

SDK's `query()` async iterator emits structured messages (`system`, `assistant`, `result`). Forward to control plane, route to clients.

**6.5 Background Process Manager**

Supervisor daemon inside VM tracking spawned processes, ports, dev server lifecycle.

### Phase 7: Access & Networking

**7.1 Tailscale Operator**

Install in k3s with reusable auth key. Creates per-session Tailscale nodes.

**7.2 Per-Session Preview URLs**

Service per session with `tailscale.com/hostname: sess-<id>`, LoadBalancer class: tailscale, ACL restricted to your devices.

**7.3 Control Plane Access**

Expose control plane API via Tailscale (or run on host, access via host's Tailscale IP). WebSocket endpoint for clients.

### Phase 8: Clients

**8.1 Web Client**

React + Vite SPA with:
- Session list (create, resume, archive)
- Chat panel (prompt input)
- Terminal panel (xterm.js)
- Diff viewer (Monaco)

**8.2 iOS Client**

SwiftUI with iOS 26 liquid glass design:
- Full glassmorphism (`.glassEffect()`)
- Native terminal view (or WKWebView + xterm.js)
- Dynamic Island for active sessions
- Live Activities for agent progress
- Push notifications via APNs

**8.3 Shared Protocol**

WebSocket message types for:
- Session: create, list, resume, pause, archive
- Terminal: stdin, stdout, resize
- Agent: prompt, events, interrupt
- Files: diff, preview URL

### Phase 9: Polish

**9.1 Checkpoints & Rollback** - Snapshot workspace after each agent turn (JuiceFS clone or tar). UI to view checkpoints, restore to previous state.

**9.2 Notifications** - Push notifications on agent turn complete, background task finished. APNs for iOS, web push for browser.

**9.3 Autonomous Mode** - "Plan mode" (agent plans, waits for approval) vs "Auto mode" (executes without confirmation). Configurable per-session.

**9.4 Port Detection** - Monitor `ss -tlnp` inside VM, auto-detect common ports (3000, 5173, 8000, 8080), surface as preview links.

---

## Part 6: Tech Stack

### Monorepo Structure

```
netclode/
├── apps/
│   ├── control-plane/     # Bun server (k8s client, WebSocket, session mgmt)
│   ├── agent/             # Sandbox agent (Claude SDK, runs inside VM)
│   ├── web/               # React + Vite
│   └── ios/               # Xcode project (SwiftUI)
├── packages/
│   └── protocol/          # Shared types (WSMessage, Session, AgentEvent)
├── infra/
│   ├── ansible/           # Ansible playbooks and roles for Ubuntu/Debian host
│   ├── sandbox/           # NixOS sandbox VM flake (containers still use NixOS)
│   └── k8s/               # SandboxTemplate, NetworkPolicy, etc.
├── package.json           # Bun workspace root
├── bun.lockb
└── turbo.json             # Optional: Turborepo for build caching
```

**Root `package.json`:**
```json
{
  "name": "netclode",
  "workspaces": [
    "apps/*",
    "packages/*"
  ]
}
```

- `apps/` contains deployable applications
- `packages/protocol` exports shared types between control-plane, agent, and web
- `apps/ios` lives in repo but outside Bun workspace (Xcode manages it)
- `infra/` contains all NixOS and k8s configuration

**Languages (2 total):**
- TypeScript (control plane, sandbox agent, web client)
- Swift (iOS client)

**Runtimes:**
| Component | Runtime | Key Dependencies |
|-----------|---------|------------------|
| Control Plane | Bun | `@kubernetes/client-node`, WebSocket |
| Sandbox Agent | Bun | `@anthropic-ai/claude-agent-sdk` (built-in tools: Read, Write, Edit, Bash, Glob, Grep, WebSearch, WebFetch) |
| Web Client | Vite | React, xterm.js, Monaco |
| iOS Client | Native | SwiftUI, iOS 26 liquid glass |

**Claude Agent SDK Key Features Used:**
- `query()` - Async iterator for agent interaction
- `allowedTools` - Control which built-in tools are available
- `permissionMode` - "bypassPermissions" since sandbox handles isolation
- `hooks` - PreToolUse/PostToolUse for audit logging and security
- `resume` - Session ID for multi-turn conversations
- `mcpServers` - Optional MCP integrations (e.g., Playwright)
- `agents` - Optional custom subagent definitions

**Infrastructure:**
- Host OS: Ubuntu 24.04 or Debian 12 (managed via Ansible)
- Sandbox OS: NixOS (containers/VMs still use NixOS for reproducibility)
- Orchestration: k3s + agent-sandbox CRDs
- Isolation: Kata Containers (Firecracker)
- Storage: JuiceFS + S3
- Networking: Cilium + Tailscale

---

## Part 7: Decisions Log

1. **VM Image**: NixOS minimal + dynamic `nix-shell`

   - Minimal NixOS base (~150-200MB) - just Docker, git, gh
   - Agent installs deps dynamically via `nix-shell -p`
   - `/nix/store` cached on JuiceFS PVC
   - One tool (nix) for everything - no mixed package managers
   - `nixos-generate -f raw` produces Firecracker-ready images
   - VM config is a flake = version controlled, reproducible

2. **Multi-user**: Single user only

   - Simpler auth (your API keys pre-configured)
   - No tenant isolation complexity
   - All sessions share your GitHub/Anthropic credentials
   - SDK supports multiple auth methods: Anthropic API key (primary), Amazon Bedrock (`CLAUDE_CODE_USE_BEDROCK=1`), Google Vertex AI (`CLAUDE_CODE_USE_VERTEX=1`), or Microsoft Foundry (`CLAUDE_CODE_USE_FOUNDRY=1`)

3. **Session bootstrapping**:

   - GitHub repo clone (primary)
   - Blank workspace (secondary)
   - No template snapshots initially

4. **Infrastructure**: Smaller VPS (~$20-40/mo) OR home PC

   - 16-32GB RAM
   - 1-2 warm sessions in pool
   - JuiceFS with cheap S3-compatible storage (Backblaze B2, Cloudflare R2)
   - **Home PC works fine** - Tailscale makes location irrelevant
     - No port forwarding needed
     - Access from anywhere via tailnet
     - Can run on existing hardware (old gaming PC, Mac Mini, NUC, etc.)

5. **Orchestration**: k8s + agent-sandbox
   - Full k3s stack with agent-sandbox CRDs
   - Worth the overhead for standard patterns
   - SandboxWarmPool for fast allocation

6. **Control Plane Language**: Bun/TypeScript
   - Considered: Go (best k8s client), Python (agent-sandbox SDK)
   - Chose Bun/TS because:
     - Same language as web client → shared types
     - Same language as sandbox agent
     - `@kubernetes/client-node` is sufficient
     - Control plane is thin (WebSocket proxy + k8s CRUD)
   - agent-sandbox Python SDK not useful (no PTY, no WebSocket, HTTP only)

7. **Kata Runtime**: Start with `kata-qemu`, optionally `kata-fc` later
   - `kata-qemu`: easier setup, full device support
   - `kata-fc`: faster boot (~125ms), needs devmapper snapshotter
   - WarmPool mitigates boot time anyway

8. **Nix Caching**: Host binary cache + per-session store
   - Host runs nix-serve/Harmonia on port 5000
   - VMs configured to check host cache before cache.nixos.org
   - First download goes to host cache → all sessions benefit
   - Session's own `/nix/store` persists on JuiceFS

## Part 8: Remaining Open Questions

1. **Preview port mapping**: Auto-detect listening ports, or explicit config?

2. **Notification mechanism**: Push notifications (APNs), webhooks, or polling?

3. ~~**Monorepo or multi-repo?**~~: **Decided: Monorepo** - all code in single repo with Bun workspaces

---

## Sources

- [Claude Agent SDK Documentation](https://platform.claude.com/docs/en/agent-sdk/overview)
- [Claude Agent SDK TypeScript](https://github.com/anthropics/claude-agent-sdk-typescript)
- [Claude Agent SDK Python](https://github.com/anthropics/claude-agent-sdk-python)
- [Claude Agent SDK Demo Agents](https://github.com/anthropics/claude-agent-sdk-demos)
- [agent-sandbox (kubernetes-sigs)](https://github.com/kubernetes-sigs/agent-sandbox)
- [Kata Containers + agent-sandbox integration](https://katacontainers.io/blog/kata-containers-agent-sandbox-integration/)
- [Google: Why K8s needs agent execution standard](https://opensource.googleblog.com/2025/11/unleashing-autonomous-ai-agents-why-kubernetes-needs-a-new-standard-for-agent-execution.html)
- [gVisor vs Kata vs Firecracker comparison](https://dev.to/agentsphere/choosing-a-workspace-for-ai-agents-the-ultimate-showdown-between-gvisor-kata-and-firecracker-b10)
- [agent-sandbox WarmPool performance](https://pacoxu.wordpress.com/2025/12/02/agent-sandbox-pre-warming-pool-makes-secure-containers-cold-start-lightning-fast/)
- [Claude Agent SDK Blog Post](https://www.anthropic.com/engineering/building-agents-with-the-claude-agent-sdk)
- [Claude Code sandboxing](https://www.anthropic.com/engineering/claude-code-sandboxing)
- [JuiceFS for AI workloads](https://juicefs.com/en/artificial-intelligence)
- [Tailscale K8s Operator](https://tailscale.com/kb/1236/kubernetes-operator)
- [E2B alternatives](https://northflank.com/blog/best-alternatives-to-e2b-dev-for-running-untrusted-code-in-secure-sandboxes)
- [SkyPilot self-hosted sandbox](https://blog.skypilot.co/skypilot-llm-sandbox/)
- [Docker sandbox for Claude Code](https://docs.docker.com/ai/sandboxes/claude-code/)
- [Claude Code devcontainer](https://code.claude.com/docs/en/devcontainer)
- [Modal sandbox comparison](https://modal.com/blog/top-code-agent-sandbox-products)
- [Your Firecracker blog post](https://stanislas.blog/2021/08/firecracker/)
- [HN discussion on async agents](https://news.ycombinator.com/item?id=46451764)
- [Kata + Firecracker on k3s](https://blog.cloudkernels.net/posts/kata-fc-k3s-k8s/)
- [Official Kata + Firecracker docs](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-kata-containers-with-firecracker.md)
- [Ansible k3s role](https://github.com/k3s-io/k3s-ansible)
- [Ansible best practices](https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html)
