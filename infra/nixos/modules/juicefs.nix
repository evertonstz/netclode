# JuiceFS configuration for session storage
#
# Expects secrets at:
#   /var/secrets/juicefs.env - Contains JUICEFS_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#
# Uses Redis for metadata (redis.nix must be enabled)
#
{
  config,
  lib,
  pkgs,
  ...
}: let
  redisUrl = "redis://127.0.0.1:6379/0";
in {
  # JuiceFS package
  environment.systemPackages = [pkgs.juicefs];

  # JuiceFS mount service
  systemd.services.juicefs = {
    description = "JuiceFS Mount";
    after = ["network-online.target" "redis-juicefs.service"];
    wants = ["network-online.target"];
    requires = ["redis-juicefs.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "5s";
      EnvironmentFile = "/var/secrets/juicefs.env";
    };

    preStart = ''
      # Wait for Redis
      for i in $(seq 1 30); do
        if ${pkgs.redis}/bin/redis-cli ping 2>/dev/null | grep -q PONG; then
          break
        fi
        sleep 1
      done

      # Format if not already formatted (idempotent)
      if ! ${pkgs.juicefs}/bin/juicefs status ${redisUrl} 2>/dev/null; then
        echo "Formatting JuiceFS filesystem..."
        ${pkgs.juicefs}/bin/juicefs format \
          --storage s3 \
          --bucket "$JUICEFS_BUCKET" \
          ${redisUrl} \
          netclode
      fi
    '';

    script = ''
      exec ${pkgs.juicefs}/bin/juicefs mount \
        --cache-dir /var/cache/juicefs \
        --cache-size 50000 \
        --writeback \
        --no-bgjob \
        ${redisUrl} \
        /juicefs
    '';

    postStop = ''
      ${pkgs.util-linux}/bin/umount /juicefs || true
    '';
  };

  # Create directories
  systemd.tmpfiles.rules = [
    "d /var/cache/juicefs 0750 root root -"
    "d /juicefs 0755 root root -"
    "d /juicefs/sessions 0755 root root -"
  ];
}
