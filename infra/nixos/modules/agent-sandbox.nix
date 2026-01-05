# agent-sandbox CRD installation for netclode hosts
#
# Installs agent-sandbox CRDs after Cilium is ready.
# https://github.com/kubernetes-sigs/agent-sandbox
#
{ config, lib, pkgs, ... }:
{
  # Systemd service to install agent-sandbox after Cilium is ready
  systemd.services.agent-sandbox-install = {
    description = "Install agent-sandbox CRDs";
    after = [ "cilium-install.service" ];
    requires = [ "cilium-install.service" ];
    wantedBy = [ "multi-user.target" ];

    # Only run if not already installed
    unitConfig = {
      ConditionPathExists = "!/var/lib/agent-sandbox-installed";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml";
      ExecStart = pkgs.writeShellScript "agent-sandbox-install" ''
        set -euo pipefail

        echo "Waiting for cluster to be ready..."
        for i in $(seq 1 30); do
          if ${pkgs.kubectl}/bin/kubectl get nodes | grep -q " Ready"; then
            break
          fi
          sleep 2
        done

        # Check if already installed
        if ${pkgs.kubectl}/bin/kubectl get crd sandboxes.agents.x-k8s.io &>/dev/null; then
          echo "agent-sandbox CRDs already installed"
          touch /var/lib/agent-sandbox-installed
          exit 0
        fi

        echo "Installing agent-sandbox CRDs..."
        ${pkgs.kubectl}/bin/kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.1.0/manifest.yaml
        ${pkgs.kubectl}/bin/kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.1.0/extensions.yaml

        echo "Waiting for CRDs to be established..."
        ${pkgs.kubectl}/bin/kubectl wait --for=condition=Established crd/sandboxes.agents.x-k8s.io --timeout=60s
        ${pkgs.kubectl}/bin/kubectl wait --for=condition=Established crd/sandboxtemplates.extensions.agents.x-k8s.io --timeout=60s

        # Mark as installed
        touch /var/lib/agent-sandbox-installed
        echo "agent-sandbox installation complete!"
      '';
    };
  };
}
