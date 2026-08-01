{
  config,
  lib,
  mkContainerBackend,
  ...
}:

let
  # 変更のたびに走る semgrep とは別に、project 全体の品質 gate を持つ
  serverPort = "9000";
  serverRepository = "sonarqube";
  serverDigest = "sha256:5a40959752dcc1e1408ff18d8ce35be30711323ed5612d3a49d65e093dc34454";
  serverImage = "${serverRepository}:community@${serverDigest}";

  databaseRepository = "postgres";
  databaseDigest = "sha256:af194ccf3e2d7fe367012c7b88ce8b816c5c889b18a5b316799a1f0d7eac746a";
  databaseImage = "${databaseRepository}:17-alpine@${databaseDigest}";

  database = mkContainerBackend "sonarqube-db" {
    image = databaseImage;
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
    # Elasticsearch が要求する mmap 数を確保できない環境向けの既定回避
    extraOptions = [ "--memory=4g" ];
    ports = [ serverPort ];
    deps = [ "docker-sonarqube-db.service" ];
  };
in
{
  config.my.ociImages = {
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

  config.sops.secrets."sonarqube/db_password" = { };

  config.sops.templates."sonarqube-db.env" = {
    content = ''
      POSTGRES_USER=sonarqube
      POSTGRES_PASSWORD=${config.sops.placeholder."sonarqube/db_password"}
      POSTGRES_DB=sonarqube
    '';
    restartUnits = [ "docker-sonarqube-db.service" ];
  };

  config.sops.templates."sonarqube.env" = {
    content = ''
      SONAR_JDBC_URL=jdbc:postgresql://sonarqube-db:5432/sonarqube
      SONAR_JDBC_USERNAME=sonarqube
      SONAR_JDBC_PASSWORD=${config.sops.placeholder."sonarqube/db_password"}
      SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true
    '';
    restartUnits = [ "docker-sonarqube.service" ];
  };

  # 解析対象は project ごとなので、環境が持つのは server の所在だけ
  config.my.contract.sonarqube = {
    url = "http://127.0.0.1:${serverPort}";
    ports.server = lib.toInt serverPort;
  };

  config.virtualisation.oci-containers.containers = database.containers // server.containers;
  config.systemd.services = database.systemdServices // server.systemdServices;
  config.my.doctor.units = database.doctorUnits // server.doctorUnits;
}
