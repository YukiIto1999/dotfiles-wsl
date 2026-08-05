{ lib }:

{
  name = "fixture";

  args = {
    image = "registry.example.invalid/backend:1@sha256:fixture";
    imageFile = "/nix/store/fixture-image.tar";
    environmentFiles = [ "/run/secrets/backend.env" ];
    volumes = [ "/var/lib/backend:/data" ];
    extraOptions = [
      "--memory=256m"
      "--label=fixture=true"
    ];
    ports = [
      "4100"
      "4200"
    ];
    deps = [
      "network-online.target"
      "dependency.service"
    ];
  };

  expected = {
    containers.fixture = {
      image = "registry.example.invalid/backend:1@sha256:fixture";
      imageFile = "/nix/store/fixture-image.tar";
      pull = "never";
      environmentFiles = [ "/run/secrets/backend.env" ];
      volumes = [ "/var/lib/backend:/data" ];
      extraOptions = [
        "--network=dotfiles-backends"
        "--memory=256m"
        "--label=fixture=true"
        "-p"
        "127.0.0.1:4100:4100"
        "-p"
        "127.0.0.1:4200:4200"
      ];
    };

    systemdServices.docker-fixture = {
      after = [
        "docker-dotfiles-backends-network.service"
        "network-online.target"
        "dependency.service"
      ];
      requires = [
        "docker-dotfiles-backends-network.service"
        "network-online.target"
        "dependency.service"
      ];
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = "5s";
      };
    };
  };
}
