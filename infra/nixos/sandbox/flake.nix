{
  description = "Netclode Agent Sandbox - NixOS microVM image for Kata Containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Common sandbox configuration
      sandboxModule = { config, pkgs, lib, ... }: {
        # Basic system config
        system.stateVersion = "24.11";

        # Minimal boot (Kata provides kernel)
        boot.isContainer = false;
        boot.loader.grub.enable = false;

        # Network - Kata handles this via CNI
        networking.hostName = "sandbox";
        networking.useNetworkd = true;
        systemd.network.enable = true;
        systemd.network.networks."10-eth0" = {
          matchConfig.Name = "eth0";
          networkConfig.DHCP = "yes";
        };

        # Users
        users.users.agent = {
          isNormalUser = true;
          uid = 1000;
          group = "agent";
          home = "/home/agent";
          extraGroups = [ "docker" "wheel" ];
        };
        users.groups.agent.gid = 1000;

        # Allow agent to sudo without password (for nix-shell)
        security.sudo.wheelNeedsPassword = false;

        # Essential packages
        environment.systemPackages = with pkgs; [
          # Core tools
          git
          gh
          curl
          wget
          jq
          ripgrep
          fd
          tree

          # Build tools
          gnumake
          gcc

          # Container tools
          docker
          docker-compose

          # Nix tools
          nix-direnv

          # Editor (for Claude)
          neovim

          # Bun runtime
          bun
        ];

        # Docker daemon
        virtualisation.docker = {
          enable = true;
          autoPrune.enable = true;
          daemon.settings = {
            storage-driver = "overlay2";
            log-driver = "json-file";
            log-opts = {
              max-size = "10m";
              max-file = "3";
            };
          };
        };

        # Nix configuration - use host binary cache
        nix = {
          settings = {
            experimental-features = [ "nix-command" "flakes" ];
            # Host cache (control plane exposes nix-serve on this IP)
            substituters = [
              "http://10.0.0.1:5000"
              "https://cache.nixos.org"
            ];
            trusted-public-keys = [
              # Add your host cache public key here
              # "netclode-cache:xxxxx"
              "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
            ];
            # Trust all users for nix-shell
            trusted-users = [ "root" "agent" ];
          };
        };

        # SSH (for debugging, optional)
        services.openssh = {
          enable = true;
          settings = {
            PermitRootLogin = "no";
            PasswordAuthentication = false;
          };
        };

        # Timezone
        time.timeZone = "UTC";

        # Journal - keep logs small
        services.journald.extraConfig = ''
          SystemMaxUse=100M
          RuntimeMaxUse=50M
        '';

        # Mount points for JuiceFS volumes
        # /workspace - project files (PVC mount)
        # /nix/store can be shared or per-session

        # Agent service
        systemd.services.netclode-agent = {
          description = "Netclode Agent";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" "docker.service" ];
          wants = [ "network-online.target" ];

          environment = {
            HOME = "/home/agent";
            WORKSPACE_PATH = "/workspace";
            # ANTHROPIC_API_KEY injected via k8s secret
          };
          path = [ pkgs.bun pkgs.coreutils pkgs.gnused pkgs.gnugrep ];

          serviceConfig = {
            Type = "simple";
            User = "agent";
            Group = "agent";
            WorkingDirectory = "/opt/netclode-agent";
            ExecStart = "/run/current-system/sw/bin/bun run src/index.ts";
            Restart = "on-failure";
            RestartSec = 5;

            # Security hardening
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            ReadWritePaths = [ "/workspace" "/tmp" "/home/agent" ];
          };
        };

        # Create workspace directory
        systemd.tmpfiles.rules = [
          "d /workspace 0755 agent agent -"
          "d /opt/netclode-agent 0755 agent agent -"
        ];
      };

      # Agent overlay module
      agentOverlay = import ./agent-overlay.nix;

    in {
      # NixOS configuration for the sandbox
      nixosConfigurations.sandbox = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ sandboxModule agentOverlay ];
      };

      # Generate different image formats
      packages.${system} = {
        # Raw disk image for Kata/Firecracker
        raw = nixos-generators.nixosGenerate {
          inherit system;
          modules = [ sandboxModule agentOverlay ];
          format = "raw";
        };

        # QCOW2 for Kata with QEMU
        qcow2 = nixos-generators.nixosGenerate {
          inherit system;
          modules = [ sandboxModule agentOverlay ];
          format = "qcow";
        };

        # Docker/OCI image (alternative to VM)
        docker = nixos-generators.nixosGenerate {
          inherit system;
          modules = [
            sandboxModule
            agentOverlay
            {
              # Docker-specific overrides
              virtualisation.docker.enable = false;  # No nested Docker in container mode
            }
          ];
          format = "docker";
        };
      };

      # Default package - raw for Firecracker
      defaultPackage.${system} = self.packages.${system}.raw;
    };
}
