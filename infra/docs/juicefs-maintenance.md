# JuiceFS Maintenance Guide

This document covers maintenance procedures for the JuiceFS storage backend used by Netclode agent workspaces.

## Architecture Overview

Netclode uses JuiceFS as a shared filesystem for agent workspaces:

- **Metadata Store**: Redis (in-cluster, see `infra/k8s/redis-juicefs.yaml`)
- **Data Store**: S3-compatible storage (configured in JuiceFS CSI secret)
- **CSI Driver**: JuiceFS CSI provisions PVCs for agent pods (see `infra/k8s/juicefs-config.yaml`)

Each agent workspace gets a PVC backed by a JuiceFS subpath (`/pvc-<uuid>`).

## Setup

Set these variables for the commands below:

```bash
# Kubernetes context and namespace
export CTX="netclode"
export NS="netclode"

# JuiceFS metadata URL (Redis service in cluster)
export META_URL="redis://redis-juicefs.${NS}.svc.cluster.local:6379/0"
```

## Monitoring

### Check Redis Memory Usage

```bash
kubectl --context "$CTX" -n "$NS" exec deploy/redis-juicefs -- redis-cli INFO memory | grep used_memory_human
```

### Count Inodes (Files/Directories)

```bash
kubectl --context "$CTX" -n "$NS" exec deploy/redis-juicefs -- redis-cli KEYS "i*" | wc -l
```

### Get JuiceFS Status

```bash
# Create a debug pod first (see Debug Pod section below)
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- juicefs status "$META_URL"
```

Key metrics in the output:
- `UsedSpace`: Total data stored
- `UsedInodes`: Number of files and directories
- `TrashDays`: Days before deleted files are permanently removed

## Common Issues

### 1. Trash Accumulation

**Symptom**: Redis memory and inode count grow over time even with few active workspaces.

**Cause**: JuiceFS trash cleanup runs as a background task in mount processes. CSI mount pods may be short-lived and not run the cleanup task frequently enough.

**Solution**: Set `TrashDays=0` to disable trash (recommended for ephemeral workspaces):

```bash
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- \
  juicefs config "$META_URL" --trash-days 0 --yes
```

Then run GC to clean existing trash:

```bash
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- \
  juicefs gc "$META_URL" --delete
```

### 2. Snapshot Growth

**Symptom**: `.snapshots/` directory contains many subdirectories consuming space.

**Cause**: JuiceFS CSI creates snapshots via `juicefs clone` when VolumeSnapshots are created. Each snapshot is stored at `.snapshots/<sourceVolumeID>/<snapshotID>`.

**Solution**: Delete unused VolumeSnapshots:

```bash
# List snapshots
kubectl --context "$CTX" -n "$NS" get volumesnapshots

# Delete a snapshot
kubectl --context "$CTX" -n "$NS" delete volumesnapshot <name>
```

### 3. Orphaned Data

**Symptom**: S3 bucket contains more data than expected based on active PVCs.

**Cause**: Failed deletions, interrupted operations, or bugs can leave orphaned data chunks.

**Solution**: Run garbage collection:

```bash
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- \
  juicefs gc "$META_URL" --delete
```

## Maintenance Procedures

### Creating a Debug Pod

To run JuiceFS commands, create a debug pod with full filesystem access:

```bash
cat <<EOF | kubectl --context "$CTX" -n "$NS" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: juicefs-debug
  namespace: ${NS}
spec:
  containers:
  - name: debug
    image: juicedata/mount:ce-v1.2.0
    command: ["sleep", "infinity"]
    volumeMounts:
    - name: jfs-dir
      mountPath: /mnt/jfs
    securityContext:
      privileged: true
  volumes:
  - name: jfs-dir
    emptyDir: {}
  restartPolicy: Never
EOF

# Wait for pod
kubectl --context "$CTX" -n "$NS" wait --for=condition=Ready pod/juicefs-debug --timeout=120s

# Mount JuiceFS (full root, not subpath)
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- juicefs mount "$META_URL" /mnt/jfs -d
```

### Inspecting Filesystem Contents

```bash
# List root directory
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- ls -la /mnt/jfs/

# Check active PVC directories
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- du -sh /mnt/jfs/pvc-*

# Check snapshots
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- du -sh /mnt/jfs/.snapshots/

# Check trash
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- \
  sh -c 'find /mnt/jfs/.trash/ -type f | wc -l'
```

### Running Garbage Collection

GC cleans up:
- Expired trash (when `TrashDays > 0`)
- Pending/orphaned slices
- Leaked data chunks

```bash
# Dry run (no changes)
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- juicefs gc "$META_URL"

# Actually delete orphaned data
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- juicefs gc "$META_URL" --delete
```

GC can take several minutes depending on data volume.

### Cleanup Debug Pod

```bash
kubectl --context "$CTX" -n "$NS" delete pod juicefs-debug --ignore-not-found
```

## Configuration

### Viewing Current Settings

```bash
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- juicefs status "$META_URL"
```

Key settings:
- `TrashDays`: Days before deleted files are permanently removed (0 = immediate)
- `BlockSize`: Data block size
- `Compression`: Compression algorithm
- `EncryptAlgo`: Encryption algorithm

### Changing Configuration

```bash
# View current config
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- juicefs config "$META_URL"

# Change trash days (0 = disable trash)
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- \
  juicefs config "$META_URL" --trash-days 0 --yes

# Set capacity quota (in GiB)
kubectl --context "$CTX" -n "$NS" exec juicefs-debug -- \
  juicefs config "$META_URL" --capacity 100 --yes
```

## Recommendations

For ephemeral workspaces like Netclode:

1. **Disable trash** (`TrashDays=0`): Workspaces can be re-cloned, no need for recovery
2. **Run periodic GC**: Weekly cleanup of any orphaned data
3. **Monitor Redis memory**: Alert if memory grows unexpectedly
4. **Clean up old snapshots**: Delete VolumeSnapshots that are no longer needed
