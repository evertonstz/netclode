# Kata Containers installation for Firecracker microVMs
#
# Downloads and installs Kata static binaries, configures containerd
# to use the kata-fc (Firecracker) runtime.
#
{ config, lib, pkgs, ... }:
let
  kataVersion = "3.24.0";
in
{
  # Install Kata binaries
  systemd.services.kata-install = {
    description = "Install Kata Containers";
    after = [ "network-online.target" "devmapper-pool-init.service" "devmapper-pool-restore.service" ];
    wants = [ "network-online.target" ];
    before = [ "containerd.service" ];
    wantedBy = [ "multi-user.target" ];

    unitConfig = {
      ConditionPathExists = "!/opt/kata/bin/kata-runtime";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "kata-install" ''
        set -euo pipefail

        echo "Downloading Kata Containers ${kataVersion}..."
        ${pkgs.curl}/bin/curl -L -o /tmp/kata-static.tar.zst \
          "https://github.com/kata-containers/kata-containers/releases/download/${kataVersion}/kata-static-${kataVersion}-amd64.tar.zst"

        echo "Extracting Kata binaries..."
        ${pkgs.zstd}/bin/zstdcat /tmp/kata-static.tar.zst | ${pkgs.gnutar}/bin/tar -xvf - -C /

        # Create /usr/local/bin if it doesn't exist (NixOS doesn't have it by default)
        mkdir -p /usr/local/bin

        # Create symlinks
        ln -sf /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime
        ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2

        # Create Firecracker shim wrapper
        cat > /usr/local/bin/containerd-shim-kata-fc-v2 << 'EOF'
#!/bin/bash
KATA_CONF_FILE=/opt/kata/share/defaults/kata-containers/configuration-fc.toml /opt/kata/bin/containerd-shim-kata-v2 "$@"
EOF
        chmod +x /usr/local/bin/containerd-shim-kata-fc-v2

        # Cleanup
        rm -f /tmp/kata-static.tar.zst

        echo "Kata Containers installation complete!"
      '';
    };
  };

  # Ensure /usr/local/bin is in PATH
  environment.systemPackages = [ ];
  environment.variables.PATH = lib.mkForce "/usr/local/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin";

  # Enable containerd with devmapper and Kata config
  virtualisation.containerd = {
    enable = true;
    settings = {
      version = 2;
      plugins."io.containerd.grpc.v1.cri" = {
        containerd = {
          snapshotter = "devmapper";
          default_runtime_name = "runc";
          runtimes = {
            runc = {
              runtime_type = "io.containerd.runc.v2";
            };
            kata-fc = {
              runtime_type = "io.containerd.kata-fc.v2";
              pod_annotations = [ "io.katacontainers.*" ];
            };
            kata-qemu = {
              runtime_type = "io.containerd.kata.v2";
              pod_annotations = [ "io.katacontainers.*" ];
            };
          };
        };
      };
      plugins."io.containerd.snapshotter.v1.devmapper" = {
        pool_name = "containerd-pool";
        root_path = "/var/lib/containerd/io.containerd.snapshotter.v1.devmapper";
        base_image_size = "10GB";
        discard_blocks = true;
      };
    };
  };
}
