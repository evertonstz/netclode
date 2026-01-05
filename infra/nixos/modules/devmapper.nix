# Device mapper thin-pool setup for Firecracker/Kata
#
# Firecracker requires devmapper snapshotter (not overlayfs).
# This creates a loopback-based thin-pool for containerd.
#
{ config, lib, pkgs, ... }:
{
  # Ensure lvm2 is available
  environment.systemPackages = [ pkgs.lvm2 ];
  # Create thin-pool on first boot
  systemd.services.devmapper-pool-init = {
    description = "Initialize devmapper thin-pool for containerd";
    before = [ "containerd.service" ];
    wantedBy = [ "multi-user.target" ];

    unitConfig = {
      ConditionPathExists = "!/var/lib/containerd/io.containerd.snapshotter.v1.devmapper/data";
    };

    path = with pkgs; [ coreutils util-linux lvm2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "devmapper-pool-init" ''
        set -euo pipefail

        DATA_DIR=/var/lib/containerd/io.containerd.snapshotter.v1.devmapper
        POOL_NAME=containerd-pool

        mkdir -p ''${DATA_DIR}

        echo "Creating thin-pool backing files..."
        touch "''${DATA_DIR}/data"
        truncate -s 100G "''${DATA_DIR}/data"

        touch "''${DATA_DIR}/meta"
        truncate -s 10G "''${DATA_DIR}/meta"

        DATA_DEV=$(losetup --find --show "''${DATA_DIR}/data")
        META_DEV=$(losetup --find --show "''${DATA_DIR}/meta")

        SECTOR_SIZE=512
        DATA_SIZE=$(blockdev --getsize64 -q ''${DATA_DEV})
        LENGTH_IN_SECTORS=$((DATA_SIZE / SECTOR_SIZE))
        DATA_BLOCK_SIZE=128
        LOW_WATER_MARK=32768

        echo "Creating thin-pool device..."
        dmsetup create "''${POOL_NAME}" \
          --table "0 ''${LENGTH_IN_SECTORS} thin-pool ''${META_DEV} ''${DATA_DEV} ''${DATA_BLOCK_SIZE} ''${LOW_WATER_MARK}"

        echo "Devmapper thin-pool initialized!"
      '';
    };
  };

  # Restore thin-pool on subsequent boots
  systemd.services.devmapper-pool-restore = {
    description = "Restore devmapper thin-pool for containerd";
    before = [ "containerd.service" ];
    after = [ "local-fs.target" ];
    wantedBy = [ "multi-user.target" ];

    unitConfig = {
      ConditionPathExists = "/var/lib/containerd/io.containerd.snapshotter.v1.devmapper/data";
    };

    path = with pkgs; [ coreutils util-linux lvm2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "devmapper-pool-restore" ''
        set -euo pipefail

        DATA_DIR=/var/lib/containerd/io.containerd.snapshotter.v1.devmapper
        POOL_NAME=containerd-pool

        # Check if pool already exists
        if dmsetup info "''${POOL_NAME}" &>/dev/null; then
          echo "Thin-pool already active"
          exit 0
        fi

        echo "Restoring thin-pool..."
        DATA_DEV=$(losetup --find --show "''${DATA_DIR}/data")
        META_DEV=$(losetup --find --show "''${DATA_DIR}/meta")

        SECTOR_SIZE=512
        DATA_SIZE=$(blockdev --getsize64 -q ''${DATA_DEV})
        LENGTH_IN_SECTORS=$((DATA_SIZE / SECTOR_SIZE))
        DATA_BLOCK_SIZE=128
        LOW_WATER_MARK=32768

        dmsetup create "''${POOL_NAME}" \
          --table "0 ''${LENGTH_IN_SECTORS} thin-pool ''${META_DEV} ''${DATA_DEV} ''${DATA_BLOCK_SIZE} ''${LOW_WATER_MARK}"

        echo "Thin-pool restored!"
      '';
    };
  };
}
