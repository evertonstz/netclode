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
    bind = "0.0.0.0"; # Allow access from k8s pods

    settings = {
      # Persistence
      appendonly = "yes";
      appendfsync = "everysec";

      # Memory management
      maxmemory = "256mb";
      maxmemory-policy = "noeviction"; # JuiceFS needs all data

      # Performance
      tcp-keepalive = 300;

      # Security - only allow from pod network and localhost
      # protected-mode is disabled since we control network access via firewall
    };
  };

  # Allow Redis access from localhost and k8s pod network
  networking.firewall.allowedTCPPorts = [6379];
}
