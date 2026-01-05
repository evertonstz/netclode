# Kata RuntimeClass setup for Kubernetes
#
# Creates RuntimeClass resources for kata-fc and kata-qemu after
# the cluster is ready.
#
{ config, lib, pkgs, ... }:
{
  systemd.services.kata-runtimeclass = {
    description = "Install Kata RuntimeClasses";
    after = [ "cilium-install.service" ];
    requires = [ "cilium-install.service" ];
    wantedBy = [ "multi-user.target" ];

    unitConfig = {
      ConditionPathExists = "!/var/lib/kata-runtimeclass-installed";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml";
      ExecStart = pkgs.writeShellScript "kata-runtimeclass" ''
        set -euo pipefail

        echo "Waiting for cluster to be ready..."
        for i in $(seq 1 30); do
          if ${pkgs.kubectl}/bin/kubectl get nodes | grep -q " Ready"; then
            break
          fi
          sleep 2
        done

        # Label node for Kata support
        NODE=$(${pkgs.kubectl}/bin/kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
        echo "Labeling node $NODE for Kata support..."
        ${pkgs.kubectl}/bin/kubectl label node "$NODE" katacontainers.io/kata-runtime=true --overwrite

        # Apply RuntimeClasses
        echo "Creating Kata RuntimeClasses..."
        cat <<'EOF' | ${pkgs.kubectl}/bin/kubectl apply -f -
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-fc
handler: kata-fc
overhead:
  podFixed:
    memory: "160Mi"
    cpu: "250m"
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu
handler: kata-qemu
overhead:
  podFixed:
    memory: "160Mi"
    cpu: "250m"
EOF

        touch /var/lib/kata-runtimeclass-installed
        echo "Kata RuntimeClasses installed!"
      '';
    };
  };
}
