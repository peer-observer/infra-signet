let
  # FIXME: Replace with your actual age public key (from your .agekey file).
  # Generated with "age-keygen -o <yourkey>.agekey"
  # DON'T ADD OR COMMIT AN UNENCRYPTED SECRET KEY TO GIT
  user = "age1rhzahxa2l3hvcxsl4k6tkna8kwz5uwxpg8eztljx7ygfls7jmsks4tt4aw";

  # FIXME: Replace with the SSH public keys of each container.
  # Each NixOS container generates its own SSH host key. Get them with e.g.:
  #   machinectl shell node01 /run/current-system/sw/bin/ssh-keyscan 127.0.0.1 | grep ssh-ed25519
  # Alternatively, bind-mount the host's SSH key into all containers
  # so they share one key and you only need one entry here.
  node01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMTByyz/BPvrvcZkUiC7/VAAMUOmA8iRM+9g6FsFaGtc";
  node02 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGqahSWMt9UfRHsA1bqzwOdMJLMRIeZwq2yzgiGlYk9R";
  web01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIoIXmV0QBR40VIFxmTt9jIjxJ1XP9TcIyXLicoyuypb";
in
{
  # WireGuard private keys — unused in container mode (WireGuard is
  # replaced by the bridge network), but still referenced by the
  # infra-library's base.nix when setup = false.
  "wireguard-private-key-node01.age".publicKeys = [ node01 user ];
  "wireguard-private-key-node02.age".publicKeys = [ node02 user ];
  "wireguard-private-key-web01.age".publicKeys = [ web01 user ];

  # Grafana admin password for the webserver.
  "grafana-admin-password-web01.age".publicKeys = [ web01 user ];
}
