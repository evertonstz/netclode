# Netclode Agent Sandbox

NixOS-based microVM image for running Claude Code agents inside Kata Containers.

## Features

- **Docker inside**: Full Docker daemon for container workloads
- **nix-shell**: Dynamic package installation via Nix
- **Binary cache**: Configured to use host nix-serve for fast package fetches
- **Minimal base**: ~200MB image with essential tools
- **Security**: Non-root agent user, systemd hardening

## Included Tools

- git, gh (GitHub CLI)
- Docker, docker-compose
- Bun runtime
- ripgrep, fd, jq
- gcc, make (for native builds)
- neovim

## Building

Requires Nix with flakes enabled:

```bash
# Build raw image for Kata/Firecracker (default)
./build.sh raw

# Build QCOW2 for Kata/QEMU (alternative)
./build.sh qcow2

# Build OCI image (no Docker-inside)
./build.sh docker
```

## Deployment

### 1. Copy image to k3s node

```bash
scp result/nixos.img user@node:/var/lib/kata/images/netclode-sandbox.img
```

### 2. Configure Kata Firecracker

Edit `/opt/kata/share/defaults/kata-containers/configuration-fc.toml`:

```toml
[hypervisor.firecracker]
path = "/opt/kata/bin/firecracker"
kernel = "/opt/kata/share/kata-containers/vmlinux.bin"
image = "/var/lib/kata/images/netclode-sandbox.img"
```

### 3. Apply RuntimeClass

```bash
kubectl apply -f infra/nixos/manifests/kata-runtimeclass.yaml
```

### 4. Label node for Kata

```bash
kubectl label node <node-name> katacontainers.io/kata-runtime=true
```

## Host Binary Cache Setup

For fast Nix package downloads, run nix-serve on the k3s host:

```bash
# Generate signing key (one-time)
nix-store --generate-binary-cache-key netclode-cache \
  /var/secrets/cache-priv.pem /var/secrets/cache-pub.pem

# Run nix-serve
nix-serve --port 5000 --secret-key-file /var/secrets/cache-priv.pem
```

Update the `trusted-public-keys` in `flake.nix` with your public key.

## Customization

### Adding packages

Edit `flake.nix` and add packages to `environment.systemPackages`.

### Changing agent config

The agent runs as a systemd service. Config in `flake.nix` under `systemd.services.netclode-agent`.

### Pre-warming Nix cache

SSH into a running sandbox and install common packages:

```bash
nix-shell -p nodejs python3 go rustc
```

These will be cached on the host for future sessions.

## Architecture

```
┌─────────────────────────────────────────┐
│  Kata MicroVM (NixOS)                   │
│  ┌───────────────────────────────────┐  │
│  │  netclode-agent (Bun)             │  │
│  │  ├── Claude Agent SDK             │  │
│  │  └── HTTP server :3002            │  │
│  ├───────────────────────────────────┤  │
│  │  dockerd                          │  │
│  │  └── User containers              │  │
│  ├───────────────────────────────────┤  │
│  │  /workspace (JuiceFS PVC)         │  │
│  │  /nix/store (cached packages)     │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```
