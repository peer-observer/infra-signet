{
  description = "A NixOS flake defining peer-observer infrastructure definition.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
    peer-observer-infra-library = {
      url = "github:peer-observer/infra-library";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      peer-observer-infra-library,
      disko,
    }:
    let
      # Systems we have a devShell for
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forSystem =
        system: f:
        f rec {
          inherit system;
          pkgs = import nixpkgs { inherit system; };
        };

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: (forSystem system f));

    in
    {
      formatter = forAllSystems ({ system, ... }: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      # Single host running all peer-observer services in NixOS containers.
      nixosConfigurations.signet-po = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          (import ./host.nix { inherit peer-observer-infra-library disko nixpkgs; })
          ./hardware-configuration.nix
          disko.nixosModules.disko
          ./disko.nix
        ];
      };

      # a shell with all needed tools
      # enter with `nix develop`
      devShells = forAllSystems (
        { pkgs, system, ... }:
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.nixos-anywhere
              pkgs.nixos-rebuild
              peer-observer-infra-library.packages.${system}.agenix
            ];

            shellHook = ''
              deploy() {
                local target=''${1:-signet-po}
                echo "deploying $target..."
                nixos-rebuild switch \
                --flake .#$target \
                --target-host $target \
                --build-host $target \
                --sudo \
                --show-trace
              }

              build-vm() {
                echo "building signet-peer-observer VM..."
                nixos-rebuild build-vm \
                --flake .#signet-po \
                --show-trace
              }
              export -f build-vm

              echo "use 'deploy [target-host]' to deploy (defaults to signet-po)"
              echo "use 'build-vm' to build a VM (useful when testing)"
            '';
          };
        }
      );
    };
}
