# Cilium CNI auto-installation for netclode hosts
#
# Installs Cilium via CLI after k3s starts using a systemd oneshot service.
# This avoids the chicken-and-egg problem with HelmChart bootstrap.
#
{ config, lib, pkgs, ... }:
{
  # Systemd service to install Cilium after k3s is ready
  systemd.services.cilium-install = {
    description = "Install Cilium CNI";
    after = [ "k3s.service" ];
    requires = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];

    # Only run if Cilium is not already installed
    unitConfig = {
      ConditionPathExists = "!/var/lib/cilium-installed";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml";
      ExecStart = pkgs.writeShellScript "cilium-install" ''
        set -euo pipefail

        echo "Waiting for k3s API server..."
        for i in $(seq 1 60); do
          if ${pkgs.kubectl}/bin/kubectl get nodes &>/dev/null; then
            break
          fi
          sleep 2
        done

        # Check if Cilium is already installed
        if ${pkgs.cilium-cli}/bin/cilium status &>/dev/null; then
          echo "Cilium is already installed, waiting for it to be ready..."
          ${pkgs.cilium-cli}/bin/cilium status --wait --wait-duration 5m
          touch /var/lib/cilium-installed
          echo "Cilium is ready!"
          exit 0
        fi

        echo "Installing Cilium..."
        ${pkgs.cilium-cli}/bin/cilium install \
          --set ipam.operator.clusterPoolIPv4PodCIDRList=10.42.0.0/16 \
          --set operator.replicas=1 \
          --set kubeProxyReplacement=true

        echo "Waiting for Cilium to be ready..."
        ${pkgs.cilium-cli}/bin/cilium status --wait --wait-duration 5m

        # Mark as installed
        touch /var/lib/cilium-installed
        echo "Cilium installation complete!"
      '';
    };
  };
}
