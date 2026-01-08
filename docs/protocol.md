# Agent Events Protocol

This document describes the events emitted by agents during execution. Events are streamed to connected clients (iOS, web) via WebSocket and persisted for session history.

## Event Types

### `tool_start`

Emitted when the agent begins using a tool.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | `"tool_start"` |
| `timestamp` | string | ISO 8601 timestamp |
| `tool` | string | Tool name (e.g., "Read", "Edit", "Bash") |
| `toolUseId` | string | Unique identifier for this tool invocation |
| `input` | object | Tool input parameters |

### `tool_input`

Emitted while streaming tool input (for large inputs).

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | `"tool_input"` |
| `timestamp` | string | ISO 8601 timestamp |
| `toolUseId` | string | Matches the `tool_start` event |
| `inputDelta` | string | Partial input being streamed |

### `tool_end`

Emitted when tool execution completes.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | `"tool_end"` |
| `timestamp` | string | ISO 8601 timestamp |
| `tool` | string | Tool name |
| `toolUseId` | string | Matches the `tool_start` event |
| `result` | string? | Tool output (if successful) |
| `error` | string? | Error message (if failed) |

### `file_change`

Emitted when a file is created, edited, or deleted.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | `"file_change"` |
| `timestamp` | string | ISO 8601 timestamp |
| `path` | string | File path |
| `action` | string | `"create"`, `"edit"`, or `"delete"` |
| `linesAdded` | int? | Number of lines added |
| `linesRemoved` | int? | Number of lines removed |

### `command_start`

Emitted when a shell command begins execution.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | `"command_start"` |
| `timestamp` | string | ISO 8601 timestamp |
| `command` | string | The command being executed |
| `cwd` | string? | Working directory |

### `command_end`

Emitted when a shell command completes.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | `"command_end"` |
| `timestamp` | string | ISO 8601 timestamp |
| `command` | string | The command that was executed |
| `exitCode` | int | Exit code (0 = success) |
| `output` | string? | Command output (stdout/stderr) |

### `thinking`

Emitted when the agent is reasoning (extended thinking).

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | `"thinking"` |
| `timestamp` | string | ISO 8601 timestamp |
| `content` | string | Thinking content |

### `port_exposed`

Emitted when a port is exposed for preview access via Tailscale.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | `"port_exposed"` |
| `timestamp` | string | ISO 8601 timestamp |
| `port` | int | Port number |
| `process` | string? | Process name (e.g., "node") |
| `previewUrl` | string? | Tailscale MagicDNS URL (`http://sandbox-{sessionID}:{port}`) |

This event is triggered when an agent exposes a port. The control plane updates the Tailscale service and NetworkPolicy to allow traffic, then broadcasts the event with the preview URL.
