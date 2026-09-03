{
  config,
  lib,
  ...
}:

let
  mkContainerBackend = import ../../../../platform/containers/impl/container-backend.nix {
    inherit lib;
  };
  inherit (import ../../../../platform/containers/impl/port-bindings.nix { inherit lib; })
    publishedPortBindings
    ;
  databaseRepository = "postgres";
  databaseDigest = "sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193";
  databaseImage = "${databaseRepository}:17-alpine@${databaseDigest}";

  database = mkContainerBackend "sonarqube-db" {
    image = databaseImage;
    extraOptions = [ "--memory=1g" ];
    environmentFiles = [ config.sops.templates."sonarqube-db.env".path ];
    volumes = [ "sonarqube-db:/var/lib/postgresql/data" ];
  };
in
{
  config = {
    dotfiles.platform.containers.services.sonarqube = {
      units = [ "docker-sonarqube-db.service" ];
      containerPolicy = {
        secretReaders."sonarqube-db.env" = [ "sonarqube-db" ];
        volumeOwners.sonarqube-db = [ "sonarqube-db" ];
      };
      images.sonarqube-db = {
        kind = "upstream";
        container = "sonarqube-db";
        image = databaseImage;
        repository = databaseRepository;
        digest = databaseDigest;
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
        POSTGRES_PASSWORD=${config.sops.placeholder."sonarqube/db_password"}
        POSTGRES_DB=sonarqube
      '';
    };

    virtualisation.oci-containers.containers = database.containers;
    assertions = [
      {
        assertion =
          publishedPortBindings config.virtualisation.oci-containers.containers.sonarqube-db == [ ];
        message = "the internal SonarQube database must not publish a host port";
      }
    ];
    systemd.services = database.systemdServices;
  };
}
