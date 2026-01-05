# Tailscale configuration with auto-connect for netclode hosts
#
# To auto-authenticate at deploy time, create the authkey file:
#   echo "tskey-auth-xxx" > /tmp/tailscale-authkey
#   nixos-anywhere --extra-files /tmp:/etc/secrets ...
#
# The authkey will be placed at /etc/secrets/tailscale-authkey
#
{ config, lib, pkgs, ... }:
{
  # Enable Tailscale
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
  };

  # Open firewall for Tailscale
  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ config.services.tailscale.port ];
  };

  # Auto-connect service that runs after tailscaled starts
  systemd.services.tailscale-autoconnect = {
    description = "Automatic Tailscale connection";
    after = [ "tailscaled.service" ];
    requires = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "tailscale-autoconnect" ''
        set -euo pipefail

        # Wait for tailscaled to be ready
        sleep 2

        # Check if already authenticated
        status="$(${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.BackendState // "NoState"')"
        if [ "$status" = "Running" ]; then
          echo "Tailscale already connected"
          exit 0
        fi

        # Look for authkey in multiple locations
        authkey=""
        for keyfile in /etc/secrets/tailscale-authkey /run/secrets/tailscale-authkey /etc/tailscale-authkey; do
          if [ -f "$keyfile" ]; then
            authkey="$(cat "$keyfile")"
            echo "Found authkey at $keyfile"
            break
          fi
        done

        if [ -z "$authkey" ]; then
          echo "No authkey found. To authenticate manually, run:"
          echo "  tailscale up --auth-key=tskey-xxx --ssh"
          exit 0
        fi

        echo "Connecting to Tailscale..."
        ${pkgs.tailscale}/bin/tailscale up --auth-key="$authkey" --ssh

        # Remove authkey file after successful auth (one-time use)
        for keyfile in /etc/secrets/tailscale-authkey /run/secrets/tailscale-authkey /etc/tailscale-authkey; do
          if [ -f "$keyfile" ]; then
            rm -f "$keyfile"
            echo "Removed $keyfile"
          fi
        done

        echo "Tailscale connected!"
      '';
    };
  };
}
