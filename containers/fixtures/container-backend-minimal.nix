{ lib }:

{
  name = "minimal";

  args.image = "registry.example.invalid/minimal:1@sha256:fixture";

  expected = {
    containers.minimal = {
      image = "registry.example.invalid/minimal:1@sha256:fixture";
      pull = "never";
      extraOptions = [ "--network=dotfiles-backends" ];
    };

    systemdServices.docker-minimal = {
      after = [ "docker-dotfiles-backends-network.service" ];
      requires = [ "docker-dotfiles-backends-network.service" ];
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = "5s";
      };
    };
  };
}
