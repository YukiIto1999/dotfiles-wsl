{
  config,
  lib,
  ...
}:

let
  mkContainerBackend = import ../../../../platform/containers/impl/container-backend.nix {
    inherit lib;
  };
  serverPort = "9000";
  serverRepository = "sonarqube";
  serverDigest = "sha256:160bd2f6a3485bd09b655ef22dd63c02bd1fa7ba82aa5d9973fd010b8bcca0b3";
  serverImage = "${serverRepository}:community@${serverDigest}";

  server = mkContainerBackend "sonarqube" {
    image = serverImage;
    environmentFiles = [ config.sops.templates."sonarqube.env".path ];
    volumes = [
      "sonarqube-data:/opt/sonarqube/data"
      "sonarqube-extensions:/opt/sonarqube/extensions"
      "sonarqube-logs:/opt/sonarqube/logs"
    ];
    extraOptions = [ "--memory=4g" ];
    ports = [ serverPort ];
    deps = [ "docker-sonarqube-db.service" ];
  };
in
{
  options.dotfiles.capabilities.code-quality.sonarqube.credentials.adminPasswordFile = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
  };

  config = {
    dotfiles.capabilities.code-quality.sonarqube.credentials.adminPasswordFile =
      config.sops.secrets."sonarqube/admin_password".path;

    dotfiles.platform.containers.services.sonarqube = {
      endpoints.http = {
        protocol = "http";
        address = "127.0.0.1";
        port = 9000;
        url = "http://127.0.0.1:9000";
      };
      units = lib.mkBefore [ "docker-sonarqube.service" ];
      containerPolicy = {
        secretReaders."sonarqube.env" = [ "sonarqube" ];
        volumeOwners.sonarqube = [
          "sonarqube-data"
          "sonarqube-extensions"
          "sonarqube-logs"
        ];
      };
      images.sonarqube = {
        kind = "upstream";
        container = "sonarqube";
        image = serverImage;
        repository = serverRepository;
        digest = serverDigest;
      };
      health = {
        endpoint = "http";
        method = "GET";
        path = "/api/system/status";
        timeout = 10;
      };
    };

    sops.secrets."sonarqube/admin_password" = {
      mode = "0400";
      owner = config.dotfiles.workstation.username;
      group = "users";
      # server 側の password は secret file の差し替えだけでは rotate できない。
      # front を新値で先に再起動しないよう、自動 restart は行わない。
      restartUnits = [ ];
    };

    # WSL は Elasticsearch が要求する vm.max_map_count を満たさない。
    sops.templates."sonarqube.env" = {
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "docker-sonarqube.service" ];
      content = ''
        SONAR_JDBC_URL=jdbc:postgresql://sonarqube-db:5432/sonarqube
        SONAR_JDBC_USERNAME=sonarqube
        SONAR_JDBC_PASSWORD=${config.sops.placeholder."sonarqube/db_password"}
        SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true
      '';
    };

    virtualisation.oci-containers.containers = server.containers;
    systemd.services = server.systemdServices;
  };
}
