# Redis for JuiceFS metadata
{
  config,
  lib,
  pkgs,
  ...
}: {
  services.redis.servers.juicefs = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";

    settings = {
      # Persistence
      appendonly = "yes";
      appendfsync = "everysec";

      # Memory management
      maxmemory = "256mb";
      maxmemory-policy = "noeviction"; # JuiceFS needs all data

      # Performance
      tcp-keepalive = 300;
    };
  };

  # Open port for localhost only (k8s pods access via host network)
  networking.firewall.interfaces."lo".allowedTCPPorts = [6379];
}
