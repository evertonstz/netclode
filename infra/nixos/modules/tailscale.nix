# Tailscale configuration for k3s
#
# Uses Tailscale Operator for k8s service exposure
# Host Tailscale is for node access only
#
{
  config,
  lib,
  pkgs,
  ...
}: {
  # Enable Tailscale on host (for SSH access)
  # Auth key is optional - if not present, authenticate manually: tailscale up --ssh
  services.tailscale = {
    enable = true;
  };

  # Open firewall for Tailscale
  networking.firewall = {
    trustedInterfaces = ["tailscale0"];
    allowedUDPPorts = [config.services.tailscale.port];
  };

  # Auto-connect with auth key if present
  systemd.services.tailscale-autoconnect = {
    description = "Automatic Tailscale connection";
    after = ["tailscaled.service"];
    requires = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [pkgs.tailscale pkgs.jq];

    script = ''
      set -euo pipefail
      sleep 2

      # Check if already authenticated
      status="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "NoState"')"
      if [ "$status" = "Running" ]; then
        echo "Tailscale already connected"
        exit 0
      fi

      # Use auth key if present
      if [ -f /var/secrets/tailscale-authkey ]; then
        authkey="$(cat /var/secrets/tailscale-authkey)"
        echo "Connecting to Tailscale..."
        tailscale up --auth-key="$authkey" --ssh
        rm -f /var/secrets/tailscale-authkey
        echo "Tailscale connected!"
      else
        echo "No auth key found. Authenticate manually: tailscale up --ssh"
      fi
    '';
  };

  # Deploy Tailscale Operator to k3s
  systemd.services.deploy-tailscale-operator = {
    description = "Deploy Tailscale Kubernetes Operator";
    after = ["k3s.service"];
    requires = ["k3s.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [pkgs.kubectl pkgs.kubernetes-helm];

    script = ''
      set -euo pipefail

      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      # Wait for k3s API to be ready
      for i in $(seq 1 30); do
        if kubectl get nodes &>/dev/null; then
          break
        fi
        echo "Waiting for k3s API..."
        sleep 2
      done

      # Check if already deployed
      if kubectl get deployment -n tailscale operator &>/dev/null; then
        echo "Tailscale Operator already deployed"
        exit 0
      fi

      # Check for OAuth credentials
      if [ ! -f /var/secrets/ts-oauth-client-id ] || [ ! -f /var/secrets/ts-oauth-client-secret ]; then
        echo "Tailscale OAuth credentials not found at /var/secrets/ts-oauth-client-id and /var/secrets/ts-oauth-client-secret"
        echo "Please create an OAuth client at https://login.tailscale.com/admin/settings/oauth"
        exit 1
      fi

      # Add Tailscale Helm repo
      helm repo add tailscale https://pkgs.tailscale.com/helmcharts || true
      helm repo update

      # Deploy operator
      echo "Deploying Tailscale Operator..."
      helm upgrade --install tailscale-operator tailscale/tailscale-operator \
        --namespace tailscale \
        --create-namespace \
        --set oauth.clientId="$(cat /var/secrets/ts-oauth-client-id)" \
        --set oauth.clientSecret="$(cat /var/secrets/ts-oauth-client-secret)" \
        --wait

      echo "Tailscale Operator deployed"
    '';
  };
}
