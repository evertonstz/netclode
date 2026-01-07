{
  description = "Netclode - Self-hosted Claude Code Cloud";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

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
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    # Host system configuration
    nixosConfigurations.netclode = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        disko.nixosModules.disko
        ./hosts/netclode-do
        ./modules/k3s.nix
        ./modules/redis.nix
        ./modules/juicefs.nix
        ./modules/juicefs-csi.nix
        ./modules/tailscale.nix
        ./modules/nix-serve.nix
      ];
    };

    # Development shell
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        nodejs_24
        kubectl
        k9s
        kubernetes-helm
        jq
        # For remote deployment
        nixos-rebuild
      ];

      shellHook = ''
        echo "Netclode development shell"
        echo "  - node: $(node --version)"
        echo "  - kubectl: $(kubectl version --client --short 2>/dev/null || echo 'not connected')"
        echo "  - nix: $(nix --version)"
      '';
    };
  };
}
