{
  config,
  lib,
  pkgs,
  mkCommand,
  mkContainerBackend,
  ...
}:

let
  # 変更のたびに走る semgrep とは別に、project 全体の品質 gate を持つ
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

  provisionAdmin = mkCommand {
    name = "dotfiles-sonarqube-provision";
    src = ./impl/provision-admin.sh;
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
    ];
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
in
{
  config.my.images = {
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

  config.sops.secrets = {
    "sonarqube/db_password" = { };
    "sonarqube/admin_password".owner = config.my.username;
  };

  config.sops.templates."sonarqube-db.env" = {
    content = ''
      POSTGRES_USER=sonarqube
      POSTGRES_PASSWORD=${config.sops.placeholder."sonarqube/db_password"}
      POSTGRES_DB=sonarqube
    '';
    restartUnits = [ "docker-sonarqube-db.service" ];
  };

  # WSL は Elasticsearch が要求する vm.max_map_count を満たさないので bootstrap check を外す
  config.sops.templates."sonarqube.env" = {
    content = ''
      SONAR_JDBC_URL=jdbc:postgresql://sonarqube-db:5432/sonarqube
      SONAR_JDBC_USERNAME=sonarqube
      SONAR_JDBC_PASSWORD=${config.sops.placeholder."sonarqube/db_password"}
      SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true
    '';
    restartUnits = [ "docker-sonarqube.service" ];
  };

  config.virtualisation.oci-containers.containers = database.containers // server.containers;
  config.systemd.services =
    database.systemdServices
    // server.systemdServices
    // {
      # 既定の admin 資格情報のまま公開しない。宣言した値へ一度だけ変える
      sonarqube-provision = {
        description = "SonarQube admin credential provisioning";
        after = [ "docker-sonarqube.service" ];
        requires = [ "docker-sonarqube.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = config.my.username;
          Environment = [
            "SONARQUBE_URL=http://127.0.0.1:${serverPort}"
            "SONARQUBE_ADMIN_PASSWORD_FILE=${config.sops.secrets."sonarqube/admin_password".path}"
          ];
          ExecStart = lib.getExe provisionAdmin;
          # cold start が 300s を超えると failed のまま二度と走らず admin/admin が残る
          Restart = "on-failure";
          RestartSec = "60s";
        };
        startLimitIntervalSec = 0;
      };
    };
}
