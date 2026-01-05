{
  description = "Netclode NixOS infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    ...
  }: {
    nixosConfigurations.netclode-do = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # Disk partitioning
        disko.nixosModules.disko
        { disko.devices.disk.disk1.device = "/dev/vda"; }

        # Host configuration
        ./hosts/netclode-do

        # Shared modules
        ./modules/devmapper.nix        # Thin-pool for Firecracker
        ./modules/kata-containers.nix  # Kata runtime with Firecracker
        ./modules/k3s.nix
        ./modules/tailscale.nix
        ./modules/cilium.nix
        ./modules/kata-runtimeclass.nix # RuntimeClass for kata-fc
        ./modules/agent-sandbox.nix
      ];
    };
  };
}
