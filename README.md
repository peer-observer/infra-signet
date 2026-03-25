# infra-signet

A signet peer-observer instance.

This instance is special, since all nodes and webservers are running in containers on the same host.

I've used the following to do the inital setup of the machine:

```
nix run github:nix-community/nixos-anywhere -- --generate-hardware-config nixos-generate-config ./hardware-configuration.nix --flake .#signet-po --target-host signet-po --disko-mode disko --build-on remote
```
