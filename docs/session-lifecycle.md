# Session Lifecycle

This document describes the session status lifecycle in Netclode's control-plane.

## Session Statuses

| Status | Meaning |
|--------|---------|
| `CREATING` | New session, sandbox being provisioned |
| `RESUMING` | Paused session being resumed, sandbox starting |
| `READY` | Sandbox running, waiting for user prompt |
| `RUNNING` | Agent actively processing a prompt |
| `PAUSED` | Sandbox deleted, session data preserved |
| `INTERRUPTED` | Agent disconnected mid-task, needs user action |
| `ERROR` | Something went wrong |

## Lifecycle Diagrams

### New Session Creation

```
CreateSession()
      |
      v
 ┌─────────┐
 │CREATING │  <-- Initial status
 └────┬────┘
      |
      v  createSandbox() [warm pool or direct]
      |
      v  sandbox becomes ready
 ┌─────────┐
 │ READY   │  <-- No pending prompt (waiting for user)
 └─────────┘
      OR
 ┌─────────┐
 │ RUNNING │  <-- Pending prompt exists (auto-processing)
 └─────────┘
```

### Normal Operation

```
 ┌─────────┐  user sends prompt   ┌─────────┐
 │ READY   │ -------------------> │ RUNNING │
 └─────────┘                      └────┬────┘
      ^                                |
      |    agent completes response    |
      +--------------------------------+
```

### Pause / Resume

```
 ┌─────────┐  sandbox deleted     ┌─────────┐
 │ READY   │ -------------------> │ PAUSED  │
 └─────────┘  (idle timeout)      └────┬────┘
                                       |
                                       | Resume() called
                                       v
                                 ┌──────────┐
                                 │ RESUMING │  <-- Creating new sandbox
                                 └────┬─────┘
                                      |
                                      v sandbox ready
                                 ┌─────────┐
                                 │ READY   │
                                 └─────────┘
```

### Agent Disconnect (while running)

```
 ┌─────────┐  agent disconnects   ┌─────────────┐
 │ RUNNING │ -------------------> │ INTERRUPTED │
 └─────────┘  (crash/timeout)     └─────────────┘
```

The user must acknowledge and decide: retry the prompt or continue.

### Snapshot Restore

```
 ┌─────────┐  RestoreSnapshot()   ┌─────────┐
 │ READY   │ -------------------> │ PAUSED  │  <-- Cleanup in progress
 └─────────┘                      └────┬────┘
                                       |
                                       | Resume() with snapshotID
                                       v
                                 ┌──────────┐
                                 │ RESUMING │  <-- Restoring PVC + creating sandbox
                                 └────┬─────┘
                                      |
                                      v sandbox ready
                                 ┌─────────┐
                                 │ READY   │
                                 └─────────┘
```

## Sandbox Creation Paths

There are two paths for creating a sandbox:

| Function | When Used | Speed |
|----------|-----------|-------|
| `createSandboxViaClaim` | New sessions (warm pool enabled) | Fast (~seconds) - sandbox already running |
| `createSandboxDirect` | New sessions (no warm pool) OR snapshot restore | Slower (~30-60s) - creates from scratch |

### Why snapshot restore uses `createSandboxDirect`

The warm pool sandboxes have their own PVCs. Snapshot restore needs to:
1. Create a new PVC from the VolumeSnapshot
2. Wait for the JuiceFS restore job to complete
3. Attach the restored PVC to a new sandbox

This cannot use the warm pool path because we need control over the PVC.

## Code References

- Session state definition: `services/control-plane/internal/session/state.go`
- Session manager: `services/control-plane/internal/session/manager.go`
  - `CreateSession()` - New session creation
  - `Resume()` - Resume paused session
  - `RestoreSnapshot()` - Restore from snapshot
  - `createSandboxDirect()` - Direct sandbox creation (with optional snapshot restore)
  - `createSandboxViaClaim()` - Warm pool sandbox allocation
- Proto definition: `proto/netclode/v1/common.proto` (SessionStatus enum)
