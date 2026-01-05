# Netclode Ansible Infrastructure

Ansible playbook for provisioning netclode hosts with k3s, Cilium, Kata Containers, and supporting services.

## Prerequisites

- Ansible 2.13+
- SSH access to target hosts
- Python 3 on target hosts

Install Ansible dependencies:

```bash
ansible-galaxy collection install -r requirements.yml
```

## Environment Variables

Create a `.env` file in the project root (`/infra/..`) with:

```bash
export TAILSCALE_AUTHKEY=tskey-auth-xxx    # From https://login.tailscale.com/admin/settings/keys
export DO_SPACES_ACCESS_KEY=xxx            # DigitalOcean Spaces access key
export DO_SPACES_SECRET_KEY=xxx            # DigitalOcean Spaces secret key
```

## Usage

```bash
source /path/to/.env
ansible-playbook playbooks/site.yml
```

## What Gets Installed

| Component | Description |
|-----------|-------------|
| k3s | Lightweight Kubernetes (no traefik, no flannel, no servicelb) |
| Cilium | CNI and network policy |
| Kata Containers | Firecracker + QEMU runtimes for microVM isolation |
| agent-sandbox | Kubernetes CRDs for agent sandboxing |
| Nix | Determinate Systems Nix daemon |
| JuiceFS | CSI driver with DigitalOcean Spaces backend |
| Tailscale | Mesh VPN with SSH enabled |

## Roles

- `k3s` - Direct k3s installation via official script
- `kata` - Kata Containers with Firecracker/QEMU support
- `nix` - Nix daemon via DeterminateSystems installer
- `juicefs` - JuiceFS CSI driver for shared storage
- `tailscale` - Tailscale VPN client

## Inventory

Edit `inventory/hosts.yml` to add/modify hosts.

## RuntimeClasses

After deployment, pods can use Kata runtimes:

```yaml
apiVersion: v1
kind: Pod
spec:
  runtimeClassName: kata-fc  # or kata-qemu
  containers:
    - name: app
      image: alpine
```
