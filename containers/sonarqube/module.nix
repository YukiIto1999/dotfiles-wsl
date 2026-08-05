{
  config,
  lib,
  pkgs,
  mkCommand,
  ...
}:

let
  mkContainerBackend = import ../impl/container-backend.nix { inherit lib; };
  serverPort = "9000";
  serverRepository = "sonarqube";
  serverDigest = "sha256:160bd2f6a3485bd09b655ef22dd63c02bd1fa7ba82aa5d9973fd010b8bcca0b3";
  serverImage = "${serverRepository}:community@${serverDigest}";

  databaseRepository = "postgres";
  databaseDigest = "sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193";
  databaseImage = "${databaseRepository}:17-alpine@${databaseDigest}";

  database = mkContainerBackend "sonarqube-db" {
    image = databaseImage;
    extraOptions = [ "--memory=1g" ];
    environmentFiles = [ config.sops.templates."sonarqube-db.env".path ];
    volumes = [ "sonarqube-db:/var/lib/postgresql/data" ];
  };

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

  provisionAdmin = mkCommand {
    name = "dotfiles-sonarqube-provision";
    src = ./impl/provision-admin.sh;
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
    ];
  };
in
{
  options.dotfiles.containers.sonarqube.credentials.adminPasswordFile = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
  };

  config = {
    dotfiles.containers = {
      sonarqube.credentials.adminPasswordFile = config.sops.secrets."sonarqube/admin_password".path;

      services.sonarqube = {
        endpoints.http = {
          protocol = "http";
          address = "127.0.0.1";
          port = 9000;
          url = "http://127.0.0.1:9000";
        };
        units = [
          "docker-sonarqube.service"
          "docker-sonarqube-db.service"
        ];
        images = {
          sonarqube = {
            kind = "upstream";
            container = "sonarqube";
            image = serverImage;
            repository = serverRepository;
            digest = serverDigest;
          };
          sonarqube-db = {
            kind = "upstream";
            container = "sonarqube-db";
            image = databaseImage;
            repository = databaseRepository;
            digest = databaseDigest;
          };
        };
        health = {
          endpoint = "http";
          method = "GET";
          path = "/api/system/status";
          timeout = 10;
        };
      };
    };

    sops.secrets = {
      "sonarqube/admin_password" = {
        mode = "0400";
        owner = config.my.username;
        group = "users";
        # server 側の password は secret file の差し替えだけでは rotate できない。
        # front を新値で先に再起動しないよう、自動 restart は行わない。
        restartUnits = [ ];
      };
      "sonarqube/db_password" = {
        mode = "0400";
        owner = "root";
        group = "root";
        restartUnits = [ ];
      };
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

    virtualisation.oci-containers.containers = database.containers // server.containers;
    systemd.services =
      database.systemdServices
      // server.systemdServices
      // {
        # 既定の admin credential のまま公開せず、宣言した値へ一度だけ変える。
        sonarqube-provision = {
          description = "SonarQube admin credential provisioning";
          after = [ "docker-sonarqube.service" ];
          wants = [ "docker-sonarqube.service" ];
          # 外部 service の受理条件で activation 全体を止めない。
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            # 反復 timer が毎回 unit を起動できるよう、成功後は inactive に戻す。
            RemainAfterExit = false;
            User = config.my.username;
            Environment = [
              "SONARQUBE_URL=http://127.0.0.1:${serverPort}"
              "SONARQUBE_ADMIN_PASSWORD_FILE=${config.dotfiles.containers.sonarqube.credentials.adminPasswordFile}"
            ];
            ExecStart = lib.getExe provisionAdmin;
            # cold start の timeout 後も、admin/admin を残さず再試行する。
            Restart = "on-failure";
            RestartSec = "60s";
          };
          startLimitIntervalSec = 0;
        };
      };

    systemd.timers.sonarqube-provision = {
      description = "SonarQube admin credential provisioning";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "1h";
      };
    };
  };
}
