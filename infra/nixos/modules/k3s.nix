# k3s configuration for netclode hosts
# Matches the Ansible configuration with custom flags for Cilium CNI
# Uses external containerd for Kata/Firecracker support
{ config, lib, pkgs, ... }:
{
  # k3s service configuration
  services.k3s = {
    enable = true;
    role = "server";

    # Disable built-in components (Cilium replaces flannel and network policy)
    # Use external containerd for Kata/Firecracker support
    extraFlags = toString [
      "--disable=traefik"           # No ingress controller
      "--disable=servicelb"         # No service load balancer
      "--disable=local-storage"     # No local storage provisioner
      "--flannel-backend=none"      # Cilium handles CNI
      "--disable-network-policy"    # Cilium handles network policy
      "--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
    ];
  };

  # k3s depends on containerd being ready
  systemd.services.k3s = {
    after = [ "containerd.service" "kata-install.service" ];
    requires = [ "containerd.service" ];
  };

  # Required kernel modules for Kubernetes networking
  boot.kernelModules = [ "br_netfilter" "overlay" ];

  # Sysctl settings required for k8s
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  # Ensure iptables is available
  environment.systemPackages = with pkgs; [
    iptables
  ];

  # k3s needs these for proper operation
  networking.firewall.allowedTCPPorts = [
    6443   # Kubernetes API server
    10250  # Kubelet metrics
  ];

  # Allow all traffic on the CNI interface
  networking.firewall.trustedInterfaces = [ "cni0" "flannel.1" "cilium_host" "cilium_net" ];
}
