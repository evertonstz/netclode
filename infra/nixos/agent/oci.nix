# Build OCI image from NixOS agent configuration
#
# Usage: nix build .#agent-image
#
# Note: Kata Containers mounts the container rootfs read-only via virtio-fs.
# We use a custom init wrapper that sets up tmpfs overlays before NixOS boots.
#
{
  pkgs,
  config,
  ...
}: let
  # The NixOS system toplevel
  toplevel = config.system.build.toplevel;

  # Init wrapper script that sets up tmpfs overlays for writable paths
  # This runs before NixOS init to handle Kata's read-only virtio-fs rootfs
  initWrapper = pkgs.writeShellScript "init-wrapper" ''
    #!/bin/sh
    set -e

    echo "Setting up tmpfs overlays for Kata read-only rootfs..."

    # Mount essential filesystems first
    mount -t proc proc /proc 2>/dev/null || true
    mount -t sysfs sys /sys 2>/dev/null || true
    mount -t devtmpfs dev /dev 2>/dev/null || true
    mkdir -p /dev/pts /dev/shm
    mount -t devpts devpts /dev/pts 2>/dev/null || true
    mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true

    # Create mount point directories (rootfs might be read-only)
    # Use overlayfs on root first to make directories creatable
    mkdir -p /mnt/root-upper /mnt/root-work
    mount -t tmpfs tmpfs /mnt
    mkdir -p /mnt/root-upper /mnt/root-work

    # Create an overlay on / to make it writable
    mount -t overlay overlay -o lowerdir=/,upperdir=/mnt/root-upper,workdir=/mnt/root-work / 2>/dev/null || {
      echo "Root overlay failed, trying alternative approach..."
      # Create directories in tmpfs and bind mount
      mkdir -p /mnt/run /mnt/tmp /mnt/var /mnt/etc-upper /mnt/etc-work
      mount --bind /mnt/run /run 2>/dev/null || mount -t tmpfs tmpfs /run
      mount --bind /mnt/tmp /tmp 2>/dev/null || mount -t tmpfs tmpfs /tmp
      mount --bind /mnt/var /var 2>/dev/null || mount -t tmpfs tmpfs /var
    }

    # Ensure directories exist
    mkdir -p /run /tmp /var /etc

    # Create tmpfs for writable areas if not already mounted
    mountpoint -q /run || mount -t tmpfs -o mode=755,size=512M tmpfs /run
    mountpoint -q /tmp || mount -t tmpfs -o mode=1777,size=256M tmpfs /tmp
    mountpoint -q /var || mount -t tmpfs -o mode=755,size=256M tmpfs /var

    # Set up /etc overlay: tmpfs upper + image etc as lower
    mkdir -p /run/etc-upper /run/etc-work
    if [ -d /etc ] && ! mountpoint -q /etc; then
      mount -t overlay overlay -o lowerdir=/etc,upperdir=/run/etc-upper,workdir=/run/etc-work /etc 2>/dev/null || {
        # If overlay fails, use tmpfs and copy
        echo "Overlay mount failed for /etc, using tmpfs copy..."
        cp -a /etc /run/etc-copy 2>/dev/null || true
        mount -t tmpfs tmpfs /etc
        cp -a /run/etc-copy/* /etc/ 2>/dev/null || true
      }
    fi

    # Create required directories
    mkdir -p /var/log /var/run /var/tmp /var/lib
    mkdir -p /run/systemd /run/user

    echo "Tmpfs overlays ready, starting NixOS init..."

    # Exec to NixOS init
    exec ${toplevel}/init "$@"
  '';
in
  pkgs.dockerTools.buildLayeredImage {
    name = "ghcr.io/angristan/netclode-agent";
    tag = "latest";

    contents = [
      toplevel
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnutar
      pkgs.gzip
      pkgs.util-linux  # for mount
    ];

    config = {
      Entrypoint = ["${initWrapper}"];
      WorkingDir = "/workspace";

      Env = [
        "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin"
        "NIX_PATH=nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixpkgs"
      ];

      Labels = {
        "org.opencontainers.image.title" = "Netclode Agent";
        "org.opencontainers.image.description" = "NixOS-based agent VM for Claude Code sandboxes";
        "org.opencontainers.image.source" = "https://github.com/angristan/netclode";
      };

      ExposedPorts = {
        "3002/tcp" = {}; # Agent HTTP API
      };
    };

    # Maximize layers for better caching
    maxLayers = 125;
  }
