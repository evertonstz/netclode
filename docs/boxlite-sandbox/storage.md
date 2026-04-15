# Storage

BoxLite sandboxes use a **persistent QCOW2 disk** mounted at `/agent` inside the VM.

## What the agent sees

Inside the sandbox, the agent still works in:

```bash
/agent
```

## Where data lives on the host

BoxLite stores sandbox state under `BOXLITE_HOME_DIR`.
In Docker Compose, that defaults to:

```bash
/var/lib/boxlite
```

Under Docker volumes on the Fedora server, the actual files are typically under:

```bash
/var/lib/docker/volumes/netclode_boxlite-home/_data
```

Per-box QCOW2 disks are stored under:

```bash
<BOXLITE_HOME_DIR>/boxes/<box-id>/disks/disk.qcow2
```

You may also see:

```bash
<BOXLITE_HOME_DIR>/boxes/<box-id>/disks/guest-rootfs.qcow2
```

`disk.qcow2` is the persistent session workspace disk.

## Disk sizing

New BoxLite sessions get a QCOW2 disk sized from:

1. `SandboxResources.disk_size_gb`, if the client provides it
2. otherwise `BOXLITE_DEFAULT_DISK_SIZE_GB`
3. otherwise the server fallback of `20`

The disk is thin-provisioned, so the configured size is an upper bound, not an eagerly allocated file of that full size.

## Lifecycle

### Create

When a session starts, the control-plane creates a BoxLite box with:

- `WithDiskSizeGb(...)`
- `WithAutoRemove(false)`
- workdir `/agent`

### Pause

Pausing a session stops the BoxLite VM but preserves the box metadata and QCOW2 disk.

### Resume

Resuming a session restarts the existing BoxLite box and reuses the same QCOW2 disk.
Files written under `/agent` survive pause/resume.

### Delete

Deleting a session performs full BoxLite cleanup and removes the persisted box/disk.

## Startup logs

Agent startup logs are stored separately from the workspace disk under:

```bash
<BOXLITE_HOME_DIR>/startup-logs/<session-id>/
```

These are control-plane-side diagnostic logs, not files inside `/agent`.

## Snapshots

The storage backend is now snapshot-capable in principle because it uses QCOW2, but the current BoxLite Go SDK does **not** expose snapshot APIs yet.

So today:

- QCOW2 disk backend: **enabled**
- snapshot API support in Go SDK: **not yet available**

Current snapshot-related endpoints return an `ErrNotSupported`-style error explaining that the QCOW2 backend is ready but the Go SDK does not expose snapshots yet.
