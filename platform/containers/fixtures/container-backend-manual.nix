{ lib }:

rec {
  name = "manual";
  cgroupParent = "synthetic-manual.slice";

  args = {
    image = "registry.example.invalid/manual:1@sha256:fixture";
    deps = [ "docker-manual-db.service" ];
    activation = "manual";
  };

  expected = {
    containers.manual = {
      image = "registry.example.invalid/manual:1@sha256:fixture";
      pull = "never";
      autoStart = false;
      extraOptions = [
        "--init"
        "--network=dotfiles-backends"
        "--cgroup-parent=${cgroupParent}"
      ];
    };

    systemdServices.docker-manual = {
      after = [
        "docker-dotfiles-backends-network.service"
        "docker-manual-db.service"
      ];
      requires = [
        "docker-dotfiles-backends-network.service"
        "docker-manual-db.service"
      ];
      restartIfChanged = false;
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = "5s";
        SuccessExitStatus = "143";
      };
    };
  };
}
