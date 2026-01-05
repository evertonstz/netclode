# Netclode NixOS Infrastructure

Declarative NixOS configuration for netclode hosts using nixos-anywhere for deployment.

## Quick Start

**One-command deployment with Tailscale:**

```bash
# Create authkey file
mkdir -p /tmp/secrets
echo "tskey-auth-xxxxx" > /tmp/secrets/tailscale-authkey

# Deploy (Cilium and Tailscale are auto-configured)
cd infra/nixos
nix run github:nix-community/nixos-anywhere -- \
  --flake .#netclode-do \
  --build-on-remote \
  --extra-files /tmp/secrets:/etc/secrets \
  root@167.172.170.73
```

That's it! After ~5 minutes, the host will be:
- Running NixOS with k3s
- Cilium CNI installed and ready
- agent-sandbox CRDs installed
- Connected to your Tailscale network with SSH enabled

## What Gets Installed

- **NixOS** (unstable) - declarative, reproducible OS
- **k3s** - lightweight Kubernetes (single-node control-plane)
- **Cilium** - CNI, network policy, kube-proxy replacement
- **agent-sandbox** - Kubernetes CRDs for sandbox orchestration
- **Tailscale** - secure access with SSH

## Deployment Without Tailscale

```bash
cd infra/nixos
nix run github:nix-community/nixos-anywhere -- \
  --flake .#netclode-do \
  --build-on-remote \
  root@167.172.170.73
```

Then manually authenticate Tailscale later:
```bash
ssh root@167.172.170.73
tailscale up --auth-key=tskey-xxx --ssh
```

## Verify Deployment

```bash
ssh root@167.172.170.73

# Check services (should show active)
systemctl status k3s cilium-install agent-sandbox-install tailscale-autoconnect

# Check k3s
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes    # Should show Ready
kubectl get pods -A  # All pods should be Running

# Check Cilium
cilium status

# Check agent-sandbox CRDs
kubectl get crd | grep sandbox

# Check Tailscale
tailscale status
```

## Configuration Structure

```
infra/nixos/
├── flake.nix                    # Main flake entry point
├── hosts/
│   └── netclode-do/
│       ├── default.nix          # Host configuration
│       ├── hardware.nix         # Hardware/cloud-init config
│       └── disk-config.nix      # Disk partitioning
└── modules/
    ├── k3s.nix                  # k3s with custom flags
    ├── cilium.nix               # Cilium auto-install service
    ├── agent-sandbox.nix        # agent-sandbox CRD installer
    └── tailscale.nix            # Tailscale with auto-connect
```

## Updates

After initial deployment:

```bash
# From local machine
nixos-rebuild switch \
  --flake .#netclode-do \
  --target-host root@167.172.170.73 \
  --build-host root@167.172.170.73
```

## Comparison with Ansible

| Aspect | Ansible | NixOS |
|--------|---------|-------|
| Host OS | Debian 13 | NixOS |
| Config style | Imperative playbooks | Declarative Nix |
| Reproducibility | Good (pinned versions) | Excellent (flake.lock) |
| Rollback | Manual | Automatic (generations) |
| Disk setup | Manual/pre-existing | Disko partitions |
| Updates | Re-run playbook | nixos-rebuild switch |

## Troubleshooting

### Cilium not ready

```bash
journalctl -u cilium-install -f
cilium status
```

### Tailscale not connecting

```bash
journalctl -u tailscale-autoconnect -f
tailscale status
# Manual connect:
tailscale up --auth-key=tskey-xxx --ssh
```

### k3s issues

```bash
journalctl -u k3s -f
```
