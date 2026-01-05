# Main configuration for netclode-do host
{ lib, pkgs, ... }:
{
  imports = [
    ./hardware.nix
  ];

  # Boot loader configuration
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Hostname
  networking.hostName = "netclode-do";

  # Enable OpenSSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Base packages (matching Ansible setup)
  environment.systemPackages = with pkgs; [
    curl
    wget
    git
    htop
    vim
    jq
    unzip
    gnupg
    # Kubernetes tools
    kubectl
    kubernetes-helm
    cilium-cli
  ];

  # Locale settings
  i18n.defaultLocale = "en_US.UTF-8";

  # Timezone
  time.timeZone = "UTC";

  # Root user SSH keys
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCrGnWycdFbKsxBjuMz8AabEtv3JM6A0Hl0P8fM70M6eS6ZeupH1OilfsZZzA6lAAv9tInfnROgIEPG2tpW+KdBiKn0pSRV7eip04TNKZ75CSEfHdwgDKMhZkWvD9AXl+rrN6IQRnSMDxcvvVFw+NfHwL13P4OWoqZg/uOgmEUFqAS8UtWN9kvu802rlIwpjlJ1Jtq7zkhUoiUU+GZTWLkvBbYvj+lHgdcIDr3RaYD2rYiqm2sXxa2rXYcWHj3nyIbgqAdg+53hLOanugs00pDR9WjvsOBYjAM207FcgQ4jbuScO1Sfl7hbRaq2N+WXWI9dSx1qVCWbUp+krPJOp2WI8hjRWFOeezwK92uexByNu0ft+tfELH229vCwOAEI1Q1jbrfGpNUeLFXbhVulISfp3gHcTHHU8KicNd2/iBqqNs/pjJUMEVMB0GfaB2go7looOOosie5Z8cNaxWwpCMP+PdIT42DjW/DUjNGty4cw6tlu+neejKtdAh7+t1VdCac= stanislas@mba"
  ];

  # Firewall - allow SSH, k3s API server
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      6443  # Kubernetes API
    ];
  };

  # NixOS version
  system.stateVersion = "24.05";
}
