# JuiceFS CSI Driver for k3s
{
  config,
  lib,
  pkgs,
  ...
}: {
  # Deploy JuiceFS CSI driver via systemd service
  systemd.services.deploy-juicefs-csi = {
    description = "Deploy JuiceFS CSI driver";
    after = ["k3s.service"];
    requires = ["k3s.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [pkgs.kubectl pkgs.curl];

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
      if kubectl get deployment -n kube-system juicefs-csi-controller &>/dev/null; then
        echo "JuiceFS CSI driver already deployed"
        exit 0
      fi

      # Deploy JuiceFS CSI driver
      echo "Deploying JuiceFS CSI driver..."
      kubectl apply -f https://raw.githubusercontent.com/juicedata/juicefs-csi-driver/v0.24.6/deploy/k8s.yaml

      echo "JuiceFS CSI driver deployed"
    '';
  };
}
