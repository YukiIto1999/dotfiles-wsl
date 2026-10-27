{
  config,
  lib,
  ...
}:

let
  enabled = builtins.elem "code-quality" config.dotfiles.capabilities.resolved;
  mkContainerBackend = import ../../../../platform/containers/impl/container-backend.nix {
    inherit lib;
    cgroupParent = config.dotfiles.workstation.workload.slices.support;
  };
  inherit (import ../../../../platform/containers/impl/port-bindings.nix { inherit lib; })
    publishedPortBindings
    ;
  repository = "postgres";
  version = "17.10-alpine3.24";
  digest = "sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193";
  image = "${repository}:${version}@${digest}";
  backend = mkContainerBackend "sonarqube-db" {
    inherit image;
    environmentFiles = [ config.sops.templates."sonarqube-db.env".path ];
    volumes = [
      "sonarqube-db:/var/lib/postgresql/data"
      "${config.sops.templates."sonarqube-db-password".path}:/run/secrets/sonarqube-db-password:ro"
    ];
    extraOptions = [
      "--memory=1g"
      "--ulimit=core=0:0"
      "--memory-swap=1g"
      "--cpus=1"
      "--pids-limit=256"
      "--cap-drop=ALL"
      "--cap-add=CHOWN"
      "--cap-add=DAC_OVERRIDE"
      "--cap-add=FOWNER"
      "--cap-add=SETGID"
      "--cap-add=SETUID"
      "--security-opt=no-new-privileges"
      "--read-only"
      "--tmpfs=/var/run/postgresql:rw,nosuid,nodev,size=16m"
      "--tmpfs=/tmp:rw,nosuid,nodev,size=64m,mode=1777"
      "--stop-timeout=45"
    ];
  };
in
{
  config = lib.mkIf enabled {
    dotfiles.platform.containers.services.sonarqube = {
      units = [ "docker-sonarqube-db.service" ];
      containerPolicy = {
        secretReaders."sonarqube-db.env" = [ "sonarqube-db" ];
        secretReaders."sonarqube-db-password" = [ "sonarqube-db" ];
        volumeOwners.sonarqube-db = [ "sonarqube-db" ];
      };
      images.sonarqube-db = {
        kind = "upstream";
        container = "sonarqube-db";
        inherit image repository digest;
      };
    };
    sops.secrets."sonarqube/db_password" = {
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ ];
    };
    sops.templates."sonarqube-db.env" = {
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "docker-sonarqube-db.service" ];
      content = ''
        POSTGRES_USER=sonarqube
        POSTGRES_PASSWORD_FILE=/run/secrets/sonarqube-db-password
        POSTGRES_DB=sonarqube
      '';
    };
    sops.templates."sonarqube-db-password" = {
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "docker-sonarqube-db.service" ];
      content = config.sops.placeholder."sonarqube/db_password";
    };
    assertions = [
      {
        assertion =
          publishedPortBindings config.virtualisation.oci-containers.containers.sonarqube-db == [ ];
        message = "the internal SonarQube database must not publish a host port";
      }
    ];
    virtualisation.oci-containers.containers = backend.containers;
    systemd.services = backend.systemdServices // {
      docker-sonarqube-db = backend.systemdServices.docker-sonarqube-db // {
        serviceConfig = backend.systemdServices.docker-sonarqube-db.serviceConfig // {
          TimeoutStopSec = lib.mkForce "60s";
        };
      };
    };
  };
}
