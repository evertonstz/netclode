# Main configuration for netclode host
{
  lib,
  pkgs,
  config,
  ...
}: {
  imports = [
    ./hardware.nix
  ];

  # Boot loader
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Kernel modules for KVM/virtualization
  boot.kernelModules = ["kvm-intel" "kvm-amd" "vhost_net" "tun" "tap"];

  # Hostname
  networking.hostName = "netclode";

  # Enable OpenSSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Base packages
  environment.systemPackages = with pkgs; [
    # System tools
    curl
    wget
    git
    htop
    vim
    jq
    tmux
    ncdu

    # Container tools
    nerdctl

    # Runtime
    bun
  ];

  # Locale settings
  i18n.defaultLocale = "en_US.UTF-8";

  # Timezone
  time.timeZone = "UTC";

  # Root user SSH keys
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCrGnWycdFbKsxBjuMz8AabEtv3JM6A0Hl0P8fM70M6eS6ZeupH1OilfsZZzA6lAAv9tInfnROgIEPG2tpW+KdBiKn0pSRV7eip04TNKZ75CSEfHdwgDKMhZkWvD9AXl+rrN6IQRnSMDxcvvVFw+NfHwL13P4OWoqZg/uOgmEUFqAS8UtWN9kvu802rlIwpjlJ1Jtq7zkhUoiUU+GZTWLkvBbYvj+lHgdcIDr3RaYD2rYiqm2sXxa2rXYcWHj3nyIbgqAdg+53hLOanugs00pDR9WjvsOBYjAM207FcgQ4jbuScO1Sfl7hbRaq2N+WXWI9dSx1qVCWbUp+krPJOp2WI8hjRWFOeezwK92uexByNu0ft+tfELH229vCwOAEI1Q1jbrfGpNUeLFXbhVulISfp3gHcTHHU8KicNd2/iBqqNs/pjJUMEVMB0GfaB2go7looOOosie5Z8cNaxWwpCMP+PdIT42DjW/DUjNGty4cw6tlu+neejKtdAh7+t1VdCac= stanislas@mba"
  ];

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22]; # SSH only, rest via Tailscale
    trustedInterfaces = ["cni0"]; # k3s pod network
  };

  # NAT for VM internet access
  networking.nat = {
    enable = true;
    internalInterfaces = ["cni0"];
    externalInterface = "eth0";
  };

  # nftables rules for k3s pod network
  # Note: Network isolation for agent VMs is handled by k8s NetworkPolicy
  networking.nftables = {
    enable = true;
    tables.filter = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority 0; policy accept;

          # Allow established connections
          ct state established,related accept

          # Allow k3s pod and service network traffic
          iifname "cni0" ip daddr { 10.42.0.0/16, 10.43.0.0/16 } accept

          # Allow pods to reach the host (for API server, Redis, etc.)
          iifname "cni0" oifname "lo" accept

          # Allow pods to access internet
          iifname "cni0" accept
        }
      '';
    };
  };

  # Nix settings
  nix = {
    settings = {
      experimental-features = ["nix-command" "flakes"];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  # Create required directories
  systemd.tmpfiles.rules = [
    "d /var/lib/netclode 0750 root root -"
    "d /var/secrets 0700 root root -"
    "d /opt/netclode 0755 root root -"
  ];

  # NixOS version
  system.stateVersion = "24.11";
}
