# Netclode: Fully Declarative NixOS Architecture

## Overview

A self-hosted Claude Code Cloud with:
- **Host OS**: NixOS (declarative, reproducible)
- **VM Runtime**: containerd + nerdctl + kata-clh (Cloud Hypervisor)
- **Agent VMs**: NixOS-based OCI images
- **Storage**: JuiceFS (S3-backed) for workspaces + image layers
- **Networking**: Tailscale + nftables (no Cilium, no k8s)
- **No**: Ansible, Kubernetes, imperative scripts

```
┌─────────────────────────────────────────────────────────────────────┐
│  VPS (NixOS)                                                        │
├─────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Control Plane (Bun + systemd)                              │    │
│  │  ├── WebSocket API (clients)                                │    │
│  │  ├── Session Manager (nerdctl wrapper)                      │    │
│  │  └── JuiceFS workspace provisioning                         │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                              │                                       │
│                              ▼ nerdctl (containerd API)              │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  containerd + kata-clh runtime                              │    │
│  │  └── Cloud Hypervisor VMs (OCI images)                      │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                              │                                       │
│         ┌────────────────────┼────────────────────┐                  │
│         ▼                    ▼                    ▼                  │
│  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐          │
│  │ Agent VM 1  │      │ Agent VM 2  │      │ Agent VM N  │          │
│  │ (NixOS)     │      │ (NixOS)     │      │ (NixOS)     │          │
│  │ /workspace ─┼──────┼─────────────┼──────┼─► JuiceFS   │          │
│  └─────────────┘      └─────────────┘      └─────────────┘          │
│                                                    │                 │
│  ┌─────────────────────────────────────────────────┼───────────┐    │
│  │  JuiceFS (host mount)                           │           │    │
│  │  /juicefs/sessions/*/workspace ◄────────────────┘           │    │
│  │  /juicefs/nix-cache/                                        │    │
│  └──────────────────────────────────┬──────────────────────────┘    │
│                                     │                                │
│                                     ▼ S3 API                         │
│                          ┌─────────────────────┐                     │
│                          │  Cloudflare R2 / B2 │                     │
│                          └─────────────────────┘                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Part 1: Repository Structure

```
netclode/
├── apps/
│   ├── control-plane/          # Bun server
│   │   ├── src/
│   │   │   ├── index.ts
│   │   │   ├── config.ts
│   │   │   ├── api/
│   │   │   │   ├── ws-server.ts
│   │   │   │   └── routes/
│   │   │   ├── sessions/
│   │   │   │   ├── manager.ts      # nerdctl wrapper
│   │   │   │   ├── state.ts
│   │   │   │   └── types.ts
│   │   │   ├── runtime/
│   │   │   │   ├── nerdctl.ts      # containerd/nerdctl integration
│   │   │   │   ├── exec.ts         # exec into VMs
│   │   │   │   └── logs.ts
│   │   │   └── storage/
│   │   │       ├── juicefs.ts      # workspace provisioning
│   │   │       └── snapshots.ts
│   │   ├── package.json
│   │   └── tsconfig.json
│   │
│   ├── agent/                  # Runs inside VM
│   │   ├── src/
│   │   │   ├── index.ts
│   │   │   ├── config.ts
│   │   │   ├── sdk/
│   │   │   ├── events/
│   │   │   └── ipc/
│   │   ├── package.json
│   │   └── tsconfig.json
│   │
│   └── web/                    # React SPA
│       └── ...
│
├── packages/
│   └── protocol/               # Shared types
│       ├── src/
│       │   ├── index.ts
│       │   ├── session.ts
│       │   ├── messages.ts
│       │   └── events.ts
│       └── package.json
│
├── infra/
│   └── nixos/
│       ├── flake.nix           # Main flake (host + agent)
│       ├── flake.lock
│       │
│       ├── hosts/
│       │   └── netclode-vps/
│       │       ├── default.nix         # Host configuration
│       │       ├── hardware.nix        # Hardware-specific
│       │       ├── disk-config.nix     # disko partitioning
│       │       ├── containerd.nix      # containerd + kata
│       │       ├── juicefs.nix         # JuiceFS mount
│       │       ├── tailscale.nix       # Tailscale config
│       │       ├── networking.nix      # Firewall, nftables
│       │       └── control-plane.nix   # Control plane service
│       │
│       ├── modules/
│       │   ├── kata-containers.nix     # Kata + Cloud Hypervisor
│       │   ├── juicefs.nix             # JuiceFS service module
│       │   ├── nix-serve.nix           # Binary cache for VMs
│       │   └── netclode.nix            # Control plane module
│       │
│       └── agent/
│           ├── default.nix             # Agent VM NixOS config
│           ├── oci.nix                 # Build OCI image
│           └── packages.nix            # Agent dependencies
│
├── package.json                # Bun workspace root
├── bun.lock
├── turbo.json
└── plan-nixos.md               # This file
```

---

## Part 2: Host NixOS Configuration

### 2.1 Main Flake

```nix
# infra/nixos/flake.nix
{
  description = "Netclode - Self-hosted Claude Code Cloud";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # For deploying to remote hosts
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, deploy-rs, ... }@inputs: {

    # Host system configuration
    nixosConfigurations.netclode-vps = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        disko.nixosModules.disko
        ./hosts/netclode-vps
      ];
    };

    # Agent OCI image
    packages.x86_64-linux = {
      agent-image = self.nixosConfigurations.agent-vm.config.system.build.ociImage;

      # For local testing
      agent-vm = self.nixosConfigurations.agent-vm.config.system.build.vm;
    };

    # Agent VM configuration (used to build OCI image)
    nixosConfigurations.agent-vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./agent ];
    };

    # Deploy configuration
    deploy.nodes.netclode-vps = {
      hostname = "netclode-vps"; # Tailscale hostname or IP
      profiles.system = {
        user = "root";
        path = deploy-rs.lib.x86_64-linux.activate.nixos
          self.nixosConfigurations.netclode-vps;
      };
    };

    # Development shell
    devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
      packages = with nixpkgs.legacyPackages.x86_64-linux; [
        bun
        nodejs
        deploy-rs
        nixos-rebuild
      ];
    };
  };
}
```

### 2.2 Host Configuration

```nix
# infra/nixos/hosts/netclode-vps/default.nix
{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ./hardware.nix
    ./disk-config.nix
    ./containerd.nix
    ./juicefs.nix
    ./tailscale.nix
    ./networking.nix
    ./control-plane.nix
    ../../modules/nix-serve.nix
  ];

  # Basic system config
  system.stateVersion = "24.11";

  networking.hostName = "netclode-vps";
  time.timeZone = "UTC";

  # Enable KVM
  boot.kernelModules = [ "kvm-intel" "kvm-amd" "tun" "tap" "vhost_net" ];

  # Kernel params for better VM performance
  boot.kernelParams = [
    "intel_iommu=on"
    "iommu=pt"
  ];

  # User for control plane
  users.users.netclode = {
    isNormalUser = true;
    extraGroups = [ "docker" "kvm" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA... your-key"
    ];
  };

  # Root SSH access for deployment
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA... your-key"
  ];

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  # Essential packages
  environment.systemPackages = with pkgs; [
    git
    htop
    ncdu
    jq
    curl
    wget
    vim
    tmux
  ];

  # Garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
```

### 2.3 containerd + Kata Configuration

```nix
# infra/nixos/hosts/netclode-vps/containerd.nix
{ config, pkgs, lib, ... }:

let
  # Kata Containers with Cloud Hypervisor
  kata-containers = pkgs.kata-containers;
  cloud-hypervisor = pkgs.cloud-hypervisor;
  virtiofsd = pkgs.virtiofsd;

  # containerd config with kata-clh runtime
  containerdConfig = pkgs.writeText "containerd-config.toml" ''
    version = 2

    [plugins]
      [plugins."io.containerd.grpc.v1.cri"]
        [plugins."io.containerd.grpc.v1.cri".containerd]
          default_runtime_name = "kata-clh"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
            [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh]
              runtime_type = "io.containerd.kata-clh.v2"
              privileged_without_host_devices = true

              [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh.options]
                ConfigPath = "${kataConfig}"

            # Also keep runc for utility containers
            [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
              runtime_type = "io.containerd.runc.v2"

      [plugins."io.containerd.grpc.v1.cri".cni]
        bin_dir = "${pkgs.cni-plugins}/bin"
        conf_dir = "/etc/cni/net.d"
  '';

  # Kata configuration for Cloud Hypervisor
  kataConfig = pkgs.writeText "configuration-clh.toml" ''
    [hypervisor.clh]
    path = "${cloud-hypervisor}/bin/cloud-hypervisor"
    kernel = "${kata-containers}/share/kata-containers/vmlinux.container"

    # Use virtio-fs for shared filesystem (fast, proper POSIX)
    shared_fs = "virtio-fs"
    virtio_fs_daemon = "${virtiofsd}/bin/virtiofsd"
    virtio_fs_cache_size = 1024
    virtio_fs_cache = "always"

    # VM defaults
    default_vcpus = 2
    default_memory = 2048

    # Enable memory hotplug
    enable_mem_prealloc = false
    memory_slots = 10

    # Networking
    enable_iothreads = true

    [agent.kata]
    kernel_modules = []

    [runtime]
    enable_debug = false
    internetworking_model = "tcfilter"
    sandbox_cgroup_only = true

    # Where to store VM state
    sandbox_bind_mounts = []
  '';

  # CNI config for VM networking
  cniConfig = pkgs.writeText "10-netclode.conflist" ''
    {
      "cniVersion": "1.0.0",
      "name": "netclode",
      "plugins": [
        {
          "type": "bridge",
          "bridge": "cni0",
          "isGateway": true,
          "ipMasq": true,
          "ipam": {
            "type": "host-local",
            "ranges": [[{"subnet": "10.88.0.0/16"}]],
            "routes": [{"dst": "0.0.0.0/0"}]
          }
        },
        {
          "type": "portmap",
          "capabilities": {"portMappings": true}
        },
        {
          "type": "firewall"
        }
      ]
    }
  '';

in {
  # Enable containerd
  virtualisation.containerd = {
    enable = true;
    settings = lib.importTOML containerdConfig;
  };

  # Install nerdctl (Docker-compatible CLI)
  environment.systemPackages = with pkgs; [
    nerdctl
    cni-plugins
    kata-containers
    cloud-hypervisor
    virtiofsd
  ];

  # CNI configuration
  environment.etc."cni/net.d/10-netclode.conflist".source = cniConfig;

  # Kata config
  environment.etc."kata-containers/configuration-clh.toml".source = kataConfig;

  # Symlinks for kata runtime discovery
  systemd.tmpfiles.rules = [
    "L+ /opt/kata - - - - ${kata-containers}"
  ];
}
```

### 2.4 JuiceFS Configuration

```nix
# infra/nixos/hosts/netclode-vps/juicefs.nix
{ config, pkgs, lib, ... }:

{
  # JuiceFS package
  environment.systemPackages = [ pkgs.juicefs ];

  # Secrets (use agenix or sops-nix in production)
  # For now, expect these in /var/secrets/
  # - /var/secrets/juicefs-access-key
  # - /var/secrets/juicefs-secret-key

  # JuiceFS mount service
  systemd.services.juicefs = {
    description = "JuiceFS Mount";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStartPre = pkgs.writeShellScript "juicefs-init" ''
        # Format if not already formatted (idempotent)
        if ! ${pkgs.juicefs}/bin/juicefs status sqlite3:///var/lib/juicefs/meta.db 2>/dev/null; then
          ${pkgs.juicefs}/bin/juicefs format \
            --storage s3 \
            --bucket "$JUICEFS_BUCKET" \
            --access-key "$(cat /var/secrets/juicefs-access-key)" \
            --secret-key "$(cat /var/secrets/juicefs-secret-key)" \
            sqlite3:///var/lib/juicefs/meta.db \
            netclode
        fi
      '';

      ExecStart = ''
        ${pkgs.juicefs}/bin/juicefs mount \
          --cache-dir /var/cache/juicefs \
          --cache-size 50000 \
          --writeback \
          sqlite3:///var/lib/juicefs/meta.db \
          /juicefs
      '';

      ExecStop = "/bin/umount /juicefs";
      Restart = "on-failure";
      RestartSec = "5s";

      # Environment
      EnvironmentFile = "/var/secrets/juicefs.env";
    };
  };

  # Create directories
  systemd.tmpfiles.rules = [
    "d /var/lib/juicefs 0750 root root -"
    "d /var/cache/juicefs 0750 root root -"
    "d /juicefs 0755 root root -"
  ];
}
```

### 2.5 Tailscale Configuration

```nix
# infra/nixos/hosts/netclode-vps/tailscale.nix
{ config, pkgs, ... }:

{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";

    # Auth key from environment or secrets
    authKeyFile = "/var/secrets/tailscale-authkey";
  };

  # Allow Tailscale traffic
  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ config.services.tailscale.port ];
  };

  # Tailscale serve for control plane (optional)
  # Alternative: use tailscale serve manually or via control plane
  systemd.services.tailscale-serve = {
    description = "Tailscale Serve for Control Plane";
    after = [ "tailscaled.service" "netclode.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --https=443 http://localhost:3000";
      ExecStop = "${pkgs.tailscale}/bin/tailscale serve off";
    };
  };
}
```

### 2.6 Network Security (nftables)

```nix
# infra/nixos/hosts/netclode-vps/networking.nix
{ config, pkgs, lib, ... }:

{
  networking = {
    # Use nftables instead of iptables
    nftables.enable = true;

    firewall = {
      enable = true;

      # Public ports (if not using Tailscale exclusively)
      allowedTCPPorts = [ 22 ];

      # Tailscale handles the rest
      trustedInterfaces = [ "tailscale0" ];
    };

    # NAT for VMs to access internet
    nat = {
      enable = true;
      internalInterfaces = [ "cni0" ];
      externalInterface = "eth0"; # Adjust to your interface
    };
  };

  # Additional nftables rules for VM isolation
  networking.nftables.tables = {
    filter = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority 0; policy accept;

          # Allow established connections
          ct state established,related accept

          # Block VMs from accessing internal networks
          iifname "cni0" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10 } drop

          # Block VMs from accessing host services (except allowed)
          iifname "cni0" ip daddr 10.88.0.1 tcp dport != { 5000 } drop

          # Allow VMs to access internet
          iifname "cni0" oifname "eth0" accept
        }
      '';
    };
  };
}
```

### 2.7 Control Plane Service

```nix
# infra/nixos/hosts/netclode-vps/control-plane.nix
{ config, pkgs, lib, ... }:

let
  # Bun runtime
  bun = pkgs.bun;

  # Control plane source (in production, use a proper derivation)
  controlPlaneSrc = "/opt/netclode";

in {
  # Control plane systemd service
  systemd.services.netclode = {
    description = "Netclode Control Plane";
    after = [
      "network-online.target"
      "containerd.service"
      "juicefs.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "containerd.service" "juicefs.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      NODE_ENV = "production";
      JUICEFS_ROOT = "/juicefs";
      CONTAINERD_ADDRESS = "/run/containerd/containerd.sock";
    };

    serviceConfig = {
      Type = "simple";
      User = "root"; # Needs access to containerd socket
      Group = "root";

      WorkingDirectory = "${controlPlaneSrc}/apps/control-plane";
      ExecStart = "${bun}/bin/bun run src/index.ts";

      Restart = "always";
      RestartSec = "5s";

      # Security hardening
      NoNewPrivileges = false; # Needs to spawn VMs
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [
        "/juicefs"
        "/run/containerd"
        "/var/log/netclode"
      ];

      # Environment file for secrets
      EnvironmentFile = "/var/secrets/netclode.env";

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "netclode";
    };
  };

  # Log directory
  systemd.tmpfiles.rules = [
    "d /var/log/netclode 0750 root root -"
    "d /opt/netclode 0755 root root -"
  ];

  # Pull agent image on boot (optional)
  systemd.services.netclode-pull-image = {
    description = "Pull Netclode Agent Image";
    after = [ "containerd.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [ "netclode.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.nerdctl}/bin/nerdctl pull ghcr.io/stanislas/netclode-agent:latest";
      RemainAfterExit = true;
    };
  };
}
```

### 2.8 Nix Binary Cache for VMs

```nix
# infra/nixos/modules/nix-serve.nix
{ config, pkgs, lib, ... }:

{
  # Generate signing key if not exists
  systemd.services.nix-serve-keygen = {
    description = "Generate nix-serve signing key";
    wantedBy = [ "multi-user.target" ];
    before = [ "nix-serve.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nix-serve-keygen" ''
        if [ ! -f /var/secrets/nix-serve-private-key ]; then
          ${pkgs.nix}/bin/nix-store --generate-binary-cache-key \
            netclode-cache \
            /var/secrets/nix-serve-private-key \
            /var/secrets/nix-serve-public-key
          chmod 600 /var/secrets/nix-serve-private-key
        fi
      '';
    };
  };

  # nix-serve for VMs to fetch packages from host
  services.nix-serve = {
    enable = true;
    port = 5000;
    bindAddress = "10.88.0.1"; # Only accessible from VM network
    secretKeyFile = "/var/secrets/nix-serve-private-key";
  };

  # Open port on CNI bridge
  networking.firewall.interfaces."cni0".allowedTCPPorts = [ 5000 ];
}
```

---

## Part 3: Agent VM Image (NixOS OCI)

### 3.1 Agent NixOS Configuration

```nix
# infra/nixos/agent/default.nix
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    # Minimal profile for small image
    (modulesPath + "/profiles/minimal.nix")
  ];

  # System basics
  system.stateVersion = "24.11";

  boot.isContainer = false;

  # Kernel (provided by Kata, but define modules)
  boot.kernelModules = [ "overlay" "br_netfilter" ];

  # No bootloader (Kata provides kernel)
  boot.loader.grub.enable = false;

  # Root filesystem
  fileSystems."/" = {
    device = "/dev/vda";
    fsType = "ext4";
  };

  # Workspace mount (virtio-fs from host)
  fileSystems."/workspace" = {
    device = "workspace";
    fsType = "virtiofs";
    options = [ "defaults" ];
  };

  # Networking (DHCP from CNI)
  networking = {
    useDHCP = true;
    firewall.enable = false; # Host firewall handles isolation
  };

  # Nix configuration - use host binary cache
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];

      # Host's nix-serve is at gateway IP
      substituters = [
        "http://10.88.0.1:5000"
        "https://cache.nixos.org"
      ];

      trusted-public-keys = [
        # Will be populated at build time or runtime
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
    };

    # Allow VMs to use nix
    enable = true;
  };

  # Docker daemon
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  # Essential packages
  environment.systemPackages = with pkgs; [
    # Runtime
    bun
    nodejs_22

    # Dev tools
    git
    gh
    curl
    wget
    jq
    ripgrep
    fd

    # Nix tools
    nix-direnv
    devenv

    # Build tools
    gnumake
    gcc
  ];

  # Agent user
  users.users.agent = {
    isNormalUser = true;
    home = "/home/agent";
    extraGroups = [ "docker" ];
  };

  # Agent service
  systemd.services.agent = {
    description = "Netclode Agent";
    after = [ "network-online.target" "docker.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HOME = "/home/agent";
      WORKSPACE = "/workspace";
    };

    serviceConfig = {
      Type = "simple";
      User = "agent";
      Group = "users";
      WorkingDirectory = "/opt/agent";
      ExecStart = "${pkgs.bun}/bin/bun run src/index.ts";
      Restart = "always";
      RestartSec = "2s";

      # Get secrets from environment
      EnvironmentFile = "/run/secrets/agent.env";

      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # SSH server for debugging (optional)
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";
  };

  # Timezone
  time.timeZone = "UTC";

  # Locale
  i18n.defaultLocale = "en_US.UTF-8";
}
```

### 3.2 OCI Image Builder

```nix
# infra/nixos/agent/oci.nix
{ config, pkgs, lib, ... }:

let
  # The NixOS system configuration
  agentSystem = import ./default.nix { inherit config pkgs lib; };

in {
  # Build OCI image from NixOS configuration
  system.build.ociImage = pkgs.dockerTools.buildLayeredImage {
    name = "ghcr.io/stanislas/netclode-agent";
    tag = "latest";

    contents = [
      # The NixOS system
      config.system.build.toplevel

      # Additional tools
      pkgs.bashInteractive
      pkgs.coreutils
    ];

    config = {
      Entrypoint = [ "${config.system.build.toplevel}/init" ];
      WorkingDir = "/workspace";

      Env = [
        "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
        "NIX_PATH=nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixpkgs"
      ];

      Labels = {
        "io.containerd.image.os" = "linux";
        "io.containerd.image.arch" = "amd64";
      };
    };

    # Max layers for better caching
    maxLayers = 125;
  };

  # Alternative: raw disk image for direct Cloud Hypervisor use
  system.build.rawImage = import (pkgs.path + "/nixos/lib/make-disk-image.nix") {
    inherit config lib pkgs;
    format = "raw";
    partitionTableType = "none";
    diskSize = "auto";
    additionalSpace = "1G";
  };
}
```

### 3.3 Build Script

```bash
#!/usr/bin/env bash
# scripts/build-agent-image.sh

set -euo pipefail

cd "$(dirname "$0")/../infra/nixos"

echo "Building agent OCI image..."
nix build .#agent-image -o result-agent-image

echo "Loading image into containerd..."
nerdctl load < result-agent-image

echo "Tagging and pushing..."
nerdctl tag netclode-agent:latest ghcr.io/stanislas/netclode-agent:latest
nerdctl push ghcr.io/stanislas/netclode-agent:latest

echo "Done!"
```

---

## Part 4: Control Plane Implementation

### 4.1 nerdctl Runtime Wrapper

```typescript
// apps/control-plane/src/runtime/nerdctl.ts
import { $ } from 'bun';

const RUNTIME = 'io.containerd.kata-clh.v2';
const DEFAULT_IMAGE = 'ghcr.io/stanislas/netclode-agent:latest';

export interface VMConfig {
  sessionId: string;
  cpus?: number;
  memoryMB?: number;
  image?: string;
  env?: Record<string, string>;
}

export interface VMInfo {
  id: string;
  name: string;
  status: string;
  createdAt: string;
}

export async function createVM(config: VMConfig): Promise<string> {
  const {
    sessionId,
    cpus = 2,
    memoryMB = 2048,
    image = DEFAULT_IMAGE,
    env = {},
  } = config;

  const containerName = `sess-${sessionId}`;
  const workspacePath = `/juicefs/sessions/${sessionId}/workspace`;

  // Ensure workspace directory exists
  await $`mkdir -p ${workspacePath}`;

  // Build environment flags
  const envFlags = Object.entries({
    SESSION_ID: sessionId,
    WORKSPACE: '/workspace',
    ...env,
  }).flatMap(([k, v]) => ['--env', `${k}=${v}`]);

  // Create and start the VM
  const result = await $`nerdctl run -d \
    --runtime ${RUNTIME} \
    --name ${containerName} \
    --cpus ${cpus} \
    --memory ${memoryMB}m \
    --mount type=bind,src=${workspacePath},dst=/workspace \
    --mount type=bind,src=/var/secrets/agent.env,dst=/run/secrets/agent.env,readonly \
    --label netclode.session=${sessionId} \
    --label netclode.created=${new Date().toISOString()} \
    ${envFlags} \
    ${image}`.text();

  return result.trim(); // Container ID
}

export async function listVMs(): Promise<VMInfo[]> {
  const result = await $`nerdctl ps -a \
    --filter label=netclode.session \
    --format '{{json .}}'`.text();

  return result
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

export async function getVM(sessionId: string): Promise<VMInfo | null> {
  try {
    const result = await $`nerdctl inspect sess-${sessionId}`.json();
    return result[0];
  } catch {
    return null;
  }
}

export async function stopVM(sessionId: string): Promise<void> {
  await $`nerdctl stop sess-${sessionId}`.quiet();
}

export async function removeVM(sessionId: string): Promise<void> {
  await $`nerdctl rm -f sess-${sessionId}`.quiet();
}

export async function execInVM(
  sessionId: string,
  command: string[],
  options?: { stdin?: ReadableStream; tty?: boolean }
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const flags = options?.tty ? ['-it'] : [];

  const proc = Bun.spawn(
    ['nerdctl', 'exec', ...flags, `sess-${sessionId}`, ...command],
    {
      stdin: options?.stdin ?? 'inherit',
      stdout: 'pipe',
      stderr: 'pipe',
    }
  );

  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);

  return {
    stdout,
    stderr,
    exitCode: await proc.exited,
  };
}

export async function getVMLogs(
  sessionId: string,
  options?: { follow?: boolean; tail?: number }
): Promise<ReadableStream | string> {
  const flags = [];
  if (options?.follow) flags.push('-f');
  if (options?.tail) flags.push('--tail', String(options.tail));

  if (options?.follow) {
    const proc = Bun.spawn(['nerdctl', 'logs', ...flags, `sess-${sessionId}`], {
      stdout: 'pipe',
    });
    return proc.stdout;
  }

  return $`nerdctl logs ${flags} sess-${sessionId}`.text();
}

export async function pullImage(image: string = DEFAULT_IMAGE): Promise<void> {
  await $`nerdctl pull ${image}`;
}
```

### 4.2 Session Manager

```typescript
// apps/control-plane/src/sessions/manager.ts
import { nanoid } from 'nanoid';
import * as runtime from '../runtime/nerdctl';
import * as storage from '../storage/juicefs';
import type { Session, SessionStatus } from '@netclode/protocol';

// In-memory state (could use SQLite/Redis for persistence)
const sessions = new Map<string, Session>();

export async function createSession(options: {
  name?: string;
  repo?: string;
}): Promise<Session> {
  const sessionId = nanoid(12);
  const name = options.name || `session-${sessionId.slice(0, 6)}`;

  // Create workspace on JuiceFS
  await storage.createWorkspace(sessionId);

  // Clone repo if provided
  if (options.repo) {
    await storage.cloneRepo(sessionId, options.repo);
  }

  // Start VM
  await runtime.createVM({
    sessionId,
    env: {
      ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY!,
    },
  });

  const session: Session = {
    id: sessionId,
    name,
    status: 'running',
    repo: options.repo,
    createdAt: new Date(),
    lastActiveAt: new Date(),
  };

  sessions.set(sessionId, session);
  return session;
}

export async function listSessions(): Promise<Session[]> {
  // Sync with actual container state
  const vms = await runtime.listVMs();
  const vmIds = new Set(vms.map((vm) => vm.name.replace('sess-', '')));

  // Update statuses
  for (const [id, session] of sessions) {
    if (!vmIds.has(id)) {
      session.status = 'stopped';
    }
  }

  return Array.from(sessions.values());
}

export async function getSession(sessionId: string): Promise<Session | null> {
  return sessions.get(sessionId) ?? null;
}

export async function stopSession(sessionId: string): Promise<void> {
  await runtime.stopVM(sessionId);

  const session = sessions.get(sessionId);
  if (session) {
    session.status = 'paused';
  }
}

export async function resumeSession(sessionId: string): Promise<void> {
  const session = sessions.get(sessionId);
  if (!session) throw new Error('Session not found');

  // Recreate VM with same workspace
  await runtime.createVM({
    sessionId,
    env: {
      ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY!,
    },
  });

  session.status = 'running';
  session.lastActiveAt = new Date();
}

export async function deleteSession(sessionId: string): Promise<void> {
  await runtime.removeVM(sessionId);
  await storage.deleteWorkspace(sessionId);
  sessions.delete(sessionId);
}

export async function execInSession(
  sessionId: string,
  command: string[]
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const session = sessions.get(sessionId);
  if (session) {
    session.lastActiveAt = new Date();
  }

  return runtime.execInVM(sessionId, command);
}
```

### 4.3 JuiceFS Storage Operations

```typescript
// apps/control-plane/src/storage/juicefs.ts
import { $ } from 'bun';

const JUICEFS_ROOT = process.env.JUICEFS_ROOT || '/juicefs';

export async function createWorkspace(sessionId: string): Promise<void> {
  const path = `${JUICEFS_ROOT}/sessions/${sessionId}/workspace`;
  await $`mkdir -p ${path}`;
}

export async function deleteWorkspace(sessionId: string): Promise<void> {
  const path = `${JUICEFS_ROOT}/sessions/${sessionId}`;
  await $`rm -rf ${path}`;
}

export async function cloneRepo(sessionId: string, repoUrl: string): Promise<void> {
  const path = `${JUICEFS_ROOT}/sessions/${sessionId}/workspace`;
  await $`git clone ${repoUrl} ${path}`;
}

export async function createSnapshot(sessionId: string, name: string): Promise<void> {
  const srcPath = `${JUICEFS_ROOT}/sessions/${sessionId}/workspace`;
  const snapshotPath = `${JUICEFS_ROOT}/sessions/${sessionId}/snapshots/${name}`;

  // JuiceFS clone (fast, copy-on-write)
  await $`juicefs clone ${srcPath} ${snapshotPath}`;
}

export async function restoreSnapshot(sessionId: string, name: string): Promise<void> {
  const workspacePath = `${JUICEFS_ROOT}/sessions/${sessionId}/workspace`;
  const snapshotPath = `${JUICEFS_ROOT}/sessions/${sessionId}/snapshots/${name}`;

  // Remove current workspace and restore from snapshot
  await $`rm -rf ${workspacePath}`;
  await $`juicefs clone ${snapshotPath} ${workspacePath}`;
}

export async function listSnapshots(sessionId: string): Promise<string[]> {
  const path = `${JUICEFS_ROOT}/sessions/${sessionId}/snapshots`;

  try {
    const result = await $`ls ${path}`.text();
    return result.trim().split('\n').filter(Boolean);
  } catch {
    return [];
  }
}

export async function getWorkspaceSize(sessionId: string): Promise<number> {
  const path = `${JUICEFS_ROOT}/sessions/${sessionId}`;
  const result = await $`du -sb ${path}`.text();
  return parseInt(result.split('\t')[0], 10);
}
```

### 4.4 WebSocket Server

```typescript
// apps/control-plane/src/api/ws-server.ts
import type { ServerWebSocket } from 'bun';
import * as sessions from '../sessions/manager';
import type { WSMessage } from '@netclode/protocol';

interface WSData {
  sessionId?: string;
}

export function createWSServer() {
  return {
    async message(ws: ServerWebSocket<WSData>, message: string) {
      const msg: WSMessage = JSON.parse(message);

      switch (msg.type) {
        case 'session.create': {
          const session = await sessions.createSession({
            name: msg.name,
            repo: msg.repo,
          });
          ws.send(JSON.stringify({ type: 'session.created', session }));
          break;
        }

        case 'session.list': {
          const list = await sessions.listSessions();
          ws.send(JSON.stringify({ type: 'session.list', sessions: list }));
          break;
        }

        case 'session.stop': {
          await sessions.stopSession(msg.sessionId);
          ws.send(JSON.stringify({ type: 'session.stopped', sessionId: msg.sessionId }));
          break;
        }

        case 'session.resume': {
          await sessions.resumeSession(msg.sessionId);
          ws.send(JSON.stringify({ type: 'session.resumed', sessionId: msg.sessionId }));
          break;
        }

        case 'session.delete': {
          await sessions.deleteSession(msg.sessionId);
          ws.send(JSON.stringify({ type: 'session.deleted', sessionId: msg.sessionId }));
          break;
        }

        case 'prompt': {
          // Forward prompt to agent via exec
          const result = await sessions.execInSession(msg.sessionId, [
            'bun', 'run', '/opt/agent/src/cli.ts', 'prompt', msg.text,
          ]);
          ws.send(JSON.stringify({
            type: 'agent.response',
            sessionId: msg.sessionId,
            result: result.stdout,
          }));
          break;
        }

        case 'terminal.input': {
          // PTY handling would go here
          // For now, simple exec
          const result = await sessions.execInSession(msg.sessionId, ['sh', '-c', msg.data]);
          ws.send(JSON.stringify({
            type: 'terminal.output',
            sessionId: msg.sessionId,
            data: result.stdout + result.stderr,
          }));
          break;
        }
      }
    },

    open(ws: ServerWebSocket<WSData>) {
      console.log('Client connected');
    },

    close(ws: ServerWebSocket<WSData>) {
      console.log('Client disconnected');
    },
  };
}
```

### 4.5 Main Entry Point

```typescript
// apps/control-plane/src/index.ts
import { createWSServer } from './api/ws-server';

const PORT = parseInt(process.env.PORT || '3000', 10);

const server = Bun.serve({
  port: PORT,

  fetch(req, server) {
    const url = new URL(req.url);

    // WebSocket upgrade
    if (url.pathname === '/ws') {
      if (server.upgrade(req)) {
        return; // Upgraded
      }
      return new Response('WebSocket upgrade failed', { status: 500 });
    }

    // Health check
    if (url.pathname === '/health') {
      return new Response('ok');
    }

    // API routes could go here

    return new Response('Not found', { status: 404 });
  },

  websocket: createWSServer(),
});

console.log(`Control plane running on port ${PORT}`);
```

---

## Part 5: Deployment

### 5.1 Initial Server Setup

```bash
# 1. Create DigitalOcean droplet with NixOS
#    - Use nixos-infect on Ubuntu, OR
#    - Use custom NixOS image

# 2. Clone repo on local machine
git clone https://github.com/stanislas/netclode
cd netclode

# 3. Create secrets on server (SSH in first)
ssh root@your-server
mkdir -p /var/secrets
echo "your-tailscale-key" > /var/secrets/tailscale-authkey
echo "your-juicefs-access-key" > /var/secrets/juicefs-access-key
echo "your-juicefs-secret-key" > /var/secrets/juicefs-secret-key
cat > /var/secrets/juicefs.env << 'EOF'
JUICEFS_BUCKET=https://your-bucket.r2.cloudflarestorage.com
EOF
cat > /var/secrets/netclode.env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-...
PORT=3000
EOF
cat > /var/secrets/agent.env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-...
EOF
chmod 600 /var/secrets/*

# 4. Deploy NixOS configuration
cd netclode
nix run github:serokell/deploy-rs -- .#netclode-vps

# Or directly:
nixos-rebuild switch --flake .#netclode-vps --target-host root@your-server
```

### 5.2 Deploy Script

```bash
#!/usr/bin/env bash
# scripts/deploy.sh

set -euo pipefail

HOST="${1:-netclode-vps}"

echo "=== Deploying Netclode to $HOST ==="

# Build and deploy NixOS config
echo "Deploying NixOS configuration..."
nixos-rebuild switch --flake ".#$HOST" --target-host "root@$HOST" --use-remote-sudo

# Build and push agent image
echo "Building agent image..."
nix build .#agent-image -o result-agent-image

echo "Pushing agent image to server..."
ssh "root@$HOST" 'nerdctl load' < result-agent-image

# Sync control plane code
echo "Syncing control plane code..."
rsync -avz --delete \
  --exclude 'node_modules' \
  --exclude '.git' \
  apps/control-plane/ "root@$HOST:/opt/netclode/apps/control-plane/"

rsync -avz --delete \
  --exclude 'node_modules' \
  --exclude '.git' \
  apps/agent/ "root@$HOST:/opt/netclode/apps/agent/"

rsync -avz --delete \
  packages/ "root@$HOST:/opt/netclode/packages/"

# Install dependencies and restart
ssh "root@$HOST" << 'EOF'
  cd /opt/netclode
  bun install
  systemctl restart netclode
EOF

echo "=== Deployment complete ==="
```

### 5.3 Continuous Deployment (GitHub Actions)

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: cachix/install-nix-action@v27
        with:
          extra_nix_config: |
            access-tokens = github.com=${{ secrets.GITHUB_TOKEN }}

      - uses: cachix/cachix-action@v15
        with:
          name: netclode
          authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}

      - name: Build agent image
        run: nix build .#agent-image -o result-agent-image

      - name: Setup SSH
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan -H ${{ secrets.SERVER_HOST }} >> ~/.ssh/known_hosts

      - name: Deploy NixOS
        run: |
          nixos-rebuild switch \
            --flake .#netclode-vps \
            --target-host root@${{ secrets.SERVER_HOST }}

      - name: Push agent image
        run: |
          ssh root@${{ secrets.SERVER_HOST }} 'nerdctl load' < result-agent-image

      - name: Sync code
        run: |
          rsync -avz --delete \
            --exclude 'node_modules' --exclude '.git' \
            apps/ root@${{ secrets.SERVER_HOST }}:/opt/netclode/apps/
          rsync -avz --delete \
            packages/ root@${{ secrets.SERVER_HOST }}:/opt/netclode/packages/

      - name: Restart services
        run: |
          ssh root@${{ secrets.SERVER_HOST }} 'cd /opt/netclode && bun install && systemctl restart netclode'
```

---

## Part 6: Operations

### 6.1 Useful Commands

```bash
# SSH into server
ssh root@netclode-vps  # Via Tailscale

# Check service status
systemctl status netclode containerd juicefs

# View logs
journalctl -u netclode -f
journalctl -u containerd -f

# List running VMs
nerdctl ps --filter label=netclode.session

# Exec into a session VM
nerdctl exec -it sess-abc123 /bin/bash

# View VM logs
nerdctl logs sess-abc123

# Check JuiceFS status
juicefs status sqlite3:///var/lib/juicefs/meta.db
juicefs stats /juicefs

# Rebuild NixOS locally (for testing)
nixos-rebuild build --flake .#netclode-vps

# Update flake inputs
nix flake update

# Garbage collect old generations
ssh root@netclode-vps 'nix-collect-garbage -d'
```

### 6.2 Rollback

```bash
# List generations
ssh root@netclode-vps 'nixos-rebuild list-generations'

# Rollback to previous generation
ssh root@netclode-vps 'nixos-rebuild switch --rollback'

# Or specific generation
ssh root@netclode-vps 'nixos-rebuild switch --generation 42'
```

### 6.3 Monitoring

```nix
# Add to hosts/netclode-vps/default.nix for basic monitoring
services.prometheus = {
  enable = true;
  exporters = {
    node = {
      enable = true;
      enabledCollectors = [ "systemd" "processes" ];
    };
  };
};

# Or just use simple metrics endpoint in control plane
```

---

## Part 7: Migration Checklist

### From Current Setup

- [ ] Set up new DigitalOcean droplet with NixOS
- [ ] Configure secrets in `/var/secrets/`
- [ ] Deploy NixOS configuration
- [ ] Build and push agent image
- [ ] Test session creation/execution
- [ ] Configure Tailscale access
- [ ] Set up GitHub Actions for CI/CD
- [ ] Migrate any existing session data

### Files to Remove

```bash
# After migration, remove old infra:
rm -rf infra/ansible/
rm -rf infra/k8s/
# Keep infra/nixos/
```

### New Files Summary

```
infra/nixos/
├── flake.nix                       # Main flake
├── flake.lock
├── hosts/
│   └── netclode-vps/
│       ├── default.nix             # Main host config
│       ├── hardware.nix            # Hardware detection
│       ├── disk-config.nix         # Disk layout (disko)
│       ├── containerd.nix          # containerd + kata
│       ├── juicefs.nix             # JuiceFS service
│       ├── tailscale.nix           # Tailscale config
│       ├── networking.nix          # Firewall rules
│       └── control-plane.nix       # Control plane service
├── modules/
│   └── nix-serve.nix               # Binary cache for VMs
└── agent/
    ├── default.nix                 # Agent VM NixOS config
    └── oci.nix                     # OCI image builder
```

---

## Summary

This architecture gives you:

| Component | Before | After |
|-----------|--------|-------|
| Host OS | Debian + Ansible | NixOS (declarative) |
| Orchestration | k3s + agent-sandbox | containerd + nerdctl |
| VM Runtime | Kata (k8s-managed) | Kata-clh (containerd) |
| Networking | Cilium NetworkPolicy | nftables (NixOS) |
| Storage | JuiceFS CSI | JuiceFS (host mount + virtio-fs) |
| Image Format | k8s pod spec | OCI image |
| Deployment | Ansible playbooks | `nixos-rebuild switch` |
| Rollback | Manual | `nixos-rebuild --rollback` |

**Total overhead reduction**: ~1GB RAM (k3s stack) → ~50MB (containerd only)

**Deployment complexity**: Multiple tools → Single `nix flake`
