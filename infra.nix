{
  peer-observer-infra-library,
  disko,
  nixpkgs,
  ...
}:

let
  mkPkgs = system: import nixpkgs { inherit system; };
  customBitcoind =
    { system, overrides }: (peer-observer-infra-library.lib system).mkCustomBitcoind overrides;
in
{
  # This is the definition of a peer-observer infrastructure for signet,
  # running on a single host with NixOS containers.
  #
  # The infra-library normally assumes separate dedicated hosts connected
  # via WireGuard. Here, we run all hosts as containers on one machine,
  # connected via a bridge network. The wireguard.ip values are used as
  # container IPs on the bridge (no actual WireGuard is used).
  #
  # The configuration options are documented in
  # https://0xb10c.github.io/peer-observer-infra-library/#_infra_agenixsecretsdir

  # Global configuration options applied to all hosts (nodes and webservers).
  global = {
    admin = {
      username = "b10c";
      sshPubKeys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCtQmhXAp3F/KcaK3NzA30b2jE26zdYg6msXTXMBVJvZ8p8adHVYrl1QVFieeIjZvy1sj0gMXPOjYpgOm7OdwiZL4h0B9/FU49h+TLly6+YBwO/XYDR84WCvtv1/HVrVSIcYdMZo2+5fnGV3zxrtC/ndBheu17PbW7pvB+O7ODjxJa2tu66Q0If1cYH85PNkF3/jzsjQRwzo88eMxPEqVfp3MfYxJR53oWlXN2SUe1F/6FkeUulx9FpHgmWtPVLsGLd285GeQwsBUIRl+VnJQwCSB69YWgATR0zlRloFcfu1DhOCo5rGXnOvGmOWZ9LYpybwvuotQ8AGbsdNpZWYhQUNGF/YealVkyKABKhIHRQcGkqqqSGHpx6ui1tLkBHJWFgdCTU6eaK9OhgnjyHDJDtPGDl/Ek84JGYHp8+seHvE0/4GvQ2hQXUEUSQpxNwlwT1TKJ8uEMQuSn5zOK9TBSrYktW9h7HRe0ZQd23C6J38Lhxt9bJ3FcyfxFqogJZz3szAo0iR/bsjyeErfjKqeDHDZu4x9OISntrL42tCtNnb9ucWHo2nd+y+2X/hGQlGDdCo+RFi4cZeIHusibmr6J8FHnYgtNldamU2MYKk9R26MmPwVD/eM1Eq/sKL1jhAH3vfnxSifsQ6DvMicRiXWy/AOb3ZdZWVCLSd0mmrjkncQ== b10c"
      ];
    };
    extraConfig = {
      system.stateVersion = "25.11";
    };
  };

  # The directory where the secrets (wireguard private keys, Grafana password, ...)
  # are stored (encrypted). Even though WireGuard is disabled in container mode,
  # the infra-library modules still reference these secrets when setup = false.
  agenixSecretsDir = ./secrets;

  # Two signet nodes.
  # IPs are on a /16 subnet so all containers can reach each other via the bridge.
  nodes = {

    node01 = {
      id = 1;
      wireguard = {
        ip = "10.21.0.1";
        pubkey = "not-used-in-container-mode-node01";
      };
      # Must be false for services to actually run (node.nix gates on !setup).
      setup = false;
      arch = "x86_64-linux";
      description = ''
        v31.0rc1
      '';

      bitcoind = {
        chain = "signet";
        # Default signet P2P port.
        customPort = 38333;
      };

      extraConfig = { };
      extraModules = [ ];
    };

    node02 = {
      id = 2;
      wireguard = {
        ip = "10.21.0.2";
        pubkey = "not-used-in-container-mode-node02";
      };

      setup = false;
      arch = "x86_64-linux";
      description = ''
        Inquisition v29.2
      '';

      bitcoind = {
        chain = "signet";
        # Custom P2P port so both nodes are reachable from the outside.
        customPort = 38335;
        # bitcoin-inquisition needs python3 for the binana code generator.
        package = (customBitcoind {
          system = "x86_64-linux";
          overrides = {
            gitCommit = "88ba899b269da37c1f6bade8e7fe69aa88c2e8b9";
            gitBranch = "v29.2-inq";
            gitURL = "https://github.com/bitcoin-inquisition/bitcoin.git";
            fakeVersionMajor = "29";
            fakeVersionMinor = "2";
          };
        }).overrideAttrs (old: {
          nativeBuildInputs = old.nativeBuildInputs ++ [ (mkPkgs "x86_64-linux").python3 ];
        });
      };

      extraConfig = { };
      extraModules = [ ];
    };
  };

  webservers = {

    web01 =
      let
        domain = "signet.peer.observer";
      in
      {
        id = 1;
        setup = false;
        arch = "x86_64-linux";
        description = "The ${domain} webserver.";

        domain = domain;

        wireguard = {
          ip = "10.21.1.1";
          pubkey = "not-used-in-container-mode-web01";
        };

        grafana.admin_user = "admin"; # FIXME

        access_DANGER = "FULL_ACCESS";

        index = {
          fullAccessNotice = ''
            <div class="alert alert-info" role="alert">
              <h2>signet peer-observer</h2>
              This peer-observer instance monitors the Bitcoin signet network.
            </div>
          '';
        };

        fork-observer = {
          networkName = "signet";
          minForkHeight = 290000;
          poolIdentification = {
            network = "Signet";
          };
        };

        extraConfig = { };
        extraModules = [
          # HACK:
          # Override fork-observer node names (the upstream library uses the
          # infra.nix attrset keys as names, but we want custom display names).
          ({ config, lib, ... }:
            let
              CONSTANTS = import "${peer-observer-infra-library}/modules/constants.nix";
              nameOverrides = {
                node01 = "Bitcoin Core v31.0";
                node02 = "Inquisition v29.2";
              };
              mkNode = name: host: {
                inherit (host) id description;
                name = nameOverrides.${name} or name;
                rpcHost = host.wireguard.ip;
                rpcPort = CONSTANTS.NODE_TO_WEBSERVER_PORT;
                rpcUser = "forkobserver";
                rpcPassword = CONSTANTS.FORK_OBSERVER_RPC_PASSWORD;
              };
            in
            {
              services.fork-observer.networks = lib.mkForce [
                {
                  id = 1;
                  name = config.peer-observer.web.fork-observer.networkName;
                  description = config.peer-observer.web.fork-observer.description;
                  minForkHeight = config.peer-observer.web.fork-observer.minForkHeight;
                  poolIdentification = {
                    enable = config.peer-observer.web.fork-observer.poolIdentification.enable;
                    network = config.peer-observer.web.fork-observer.poolIdentification.network;
                  };
                  nodes = lib.attrValues (lib.mapAttrs mkNode config.infra.nodes);
                }
              ];
            })
        ];
      };
  };
}
