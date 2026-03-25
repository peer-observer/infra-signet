# Single-host configuration that runs peer-observer nodes and webserver
# as NixOS containers (systemd-nspawn) connected via a bridge network.
#
# The bridge replaces WireGuard: container IPs match the wireguard.ip
# values from infra.nix, so all the infra-library's nginx/prometheus
# config that references wireguard IPs works unchanged.

{
  peer-observer-infra-library,
  disko,
  nixpkgs,
}:

let
  infra = import ./infra.nix { inherit peer-observer-infra-library disko nixpkgs; };
  infraLib = peer-observer-infra-library.lib "x86_64-linux";

  # Common overrides applied to all containers to make them work
  # in container mode (no WireGuard, no boot-level settings).
  containerOverrides = { lib, ... }: {
    # The bridge network replaces WireGuard. Disable WireGuard so it
    # doesn't try to create interfaces or load keys.
    networking.wireguard.enable = lib.mkForce false;

    # Agenix will try to decrypt secrets at activation time. The dummy
    # .age files in secrets/ allow the build to succeed, but you must
    # replace them with properly encrypted secrets before deploying.
    # The WireGuard private key secrets are unused (WireGuard is disabled)
    # but still referenced by base.nix when setup = false.


    # Default gateway and DNS so containers can reach the internet.
    networking.defaultGateway = { address = "10.21.0.254"; interface = "eth0"; };
    networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

    # The infra-library opens port 9000 only on the wg-peerobserver interface.
    # In container mode there's no WireGuard — open it on eth0 (the bridge) instead.
    networking.firewall.interfaces."eth0".allowedTCPPorts = [ 9000 ];

    # Containers can't set boot-level or kernel-level options.
    boot.loader.grub.enable = lib.mkForce false;
    zramSwap.enable = lib.mkForce false;
    boot.tmp.cleanOnBoot = lib.mkForce false;
  };

  # Build a container definition for a node.
  mkNodeContainer = name: nodeConfig: {
    autoStart = true;
    privateNetwork = true;
    hostBridge = "br-peerobs";
    localAddress = "${nodeConfig.wireguard.ip}/16";

    # Grant capabilities needed for the eBPF extractor to attach
    # USDT probes to bitcoind.
    extraFlags = [
      "--capability=CAP_BPF"
      "--capability=CAP_PERFMON"
      "--capability=CAP_SYS_ADMIN"
      "--capability=CAP_NET_ADMIN"
    ];
    bindMounts."/sys/kernel/debug" = {
      hostPath = "/sys/kernel/debug";
      isReadOnly = false;
    };

    config = { ... }: {
      imports =
        (infraLib.mkModules nodeConfig.extraModules)
        ++ [ containerOverrides ];

      # mkNodeConfig returns an attrset suitable as a NixOS config module.
      # It sets infra, peer-observer.{node,web,base} options.
      config = infraLib.mkNodeConfig name nodeConfig infra;
    };
  };

  # Build a container definition for a webserver.
  mkWebContainer = name: webConfig: {
    autoStart = true;
    privateNetwork = true;
    hostBridge = "br-peerobs";
    localAddress = "${webConfig.wireguard.ip}/16";

    config = { lib, ... }: {
      imports =
        (infraLib.mkModules webConfig.extraModules)
        ++ [ containerOverrides ];

      config = infraLib.mkWebConfig name webConfig infra
        // {
          # FIXME: set these for ACME/TLS to work, or handle TLS on the host.
          security.acme.acceptTerms = lib.mkForce true;
          security.acme.defaults.email = lib.mkForce "signet-po-spam@b10c.me"; # FIXME
        };
    };
  };

in

# This is a NixOS module for the host machine.
{ lib, pkgs, ... }:

{
  networking.hostName = "signet-peer-observer";

  # Admin user with SSH access, matching infra.nix global config.
  users.users.${infra.global.admin.username} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = infra.global.admin.sshPubKeys;
  };

  # allow password-less sudo for admin user
  security.sudo.extraRules = [
    {
      users = [ infra.global.admin.username ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Bridge network connecting all containers.
  # All container IPs (10.21.0.x for nodes, 10.21.1.x for web) are on
  # the same /16 subnet so they can reach each other.
  networking.bridges.br-peerobs.interfaces = [ ];
  networking.interfaces.br-peerobs.ipv4.addresses = [
    { address = "10.21.0.254"; prefixLength = 16; }
  ];

  # NAT so containers can reach the internet (bitcoind needs outbound).
  networking.nat = {
    enable = true;
    internalInterfaces = [ "br-peerobs" ];
    # FIXME: set this to your actual internet-facing interface
    externalInterface = "enp1s0";
  };

  # Forward ports from host to containers.
  networking.nat.forwardPorts = [
    # Web (HTTP/HTTPS)
    { destination = "${infra.webservers.web01.wireguard.ip}:80"; proto = "tcp"; sourcePort = 80; }
    { destination = "${infra.webservers.web01.wireguard.ip}:443"; proto = "tcp"; sourcePort = 443; }
    # Bitcoin P2P (signet)
    { destination = "${infra.nodes.node01.wireguard.ip}:${toString infra.nodes.node01.bitcoind.customPort}"; proto = "tcp"; sourcePort = infra.nodes.node01.bitcoind.customPort; }
    { destination = "${infra.nodes.node02.wireguard.ip}:${toString infra.nodes.node02.bitcoind.customPort}"; proto = "tcp"; sourcePort = infra.nodes.node02.bitcoind.customPort; }
  ];
  networking.firewall.allowedTCPPorts = [
    80
    443
    infra.nodes.node01.bitcoind.customPort
    infra.nodes.node02.bitcoind.customPort
  ];

  # Mount debugfs for eBPF (needed by peer-observer ebpf extractor in containers).
  boot.kernel.sysctl."kernel.unprivileged_bpf_disabled" = 0;

  system.stateVersion = "25.11";

  # utilities installed by default
  environment.systemPackages = with pkgs; [
    wget
    vim
    curl
    htop
    git
    ripgrep
    tmux
    jq
  ];

  nix = {
    gc = {
      # Nix store garbage collection
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 7d";
    };
    settings = {
      auto-optimise-store = true;
      substituters = [ "https://b10c-nixpkgs.cachix.org" ];
      trusted-public-keys = [ "b10c-nixpkgs.cachix.org-1:okaPyE6H0JAJb4H1J8r7mnf7Gst+0c6Djz7ff3QDGkY=" ];
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
  };

  # Clean the files in `/tmp` during boot.
  boot.tmp.cleanOnBoot = true;
  # Compressed tmp files and SWAP.
  # See https://www.kernel.org/doc/Documentation/blockdev/zram.txt
  zramSwap.enable = true;

  # Generate containers from infra.nix definitions.
  containers = (lib.mapAttrs mkNodeContainer infra.nodes) // (lib.mapAttrs mkWebContainer infra.webservers);
}
