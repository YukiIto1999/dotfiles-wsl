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
  repository = "sonarqube";
  version = "26.7.0.124771-community";
  digest = "sha256:160bd2f6a3485bd09b655ef22dd63c02bd1fa7ba82aa5d9973fd010b8bcca0b3";
  image = "${repository}:${version}@${digest}";
  backend = mkContainerBackend "sonarqube" {
    inherit image;
    volumes = [
      "sonarqube-data:/opt/sonarqube/data"
      "sonarqube-extensions:/opt/sonarqube/extensions"
      "sonarqube-logs:/opt/sonarqube/logs"
      "${config.sops.templates."sonarqube.properties".path}:/opt/sonarqube/conf/sonar.properties:ro"
    ];
    extraOptions = [
      "--memory=4g"
      "--memory-swap=4g"
      "--cpus=2"
      "--ulimit=core=0:0"
      "--pids-limit=1024"
      "--ulimit=nofile=131072:131072"
      "--ulimit=nproc=8192:8192"
      "--cap-drop=ALL"
      "--security-opt=no-new-privileges"
      "--read-only"
      "--tmpfs=/tmp:rw,nosuid,nodev,size=256m,mode=1777"
      "--tmpfs=/opt/sonarqube/temp:rw,nosuid,nodev,size=512m,uid=1000,gid=1000"
      "--stop-timeout=60"
    ];
    ports = [ "9000" ];
    deps = [ "docker-sonarqube-db.service" ];
  };
in
{
  options.dotfiles.capabilities.code-quality.sonarqube.credentials = {
    adminPasswordFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
  };

  config = lib.mkIf enabled {
    dotfiles.capabilities.code-quality.sonarqube.credentials = {
      adminPasswordFile = config.sops.secrets."sonarqube/admin_password".path;
      tokenFile = config.sops.secrets."sonarqube/token".path;
    };
    dotfiles.platform.containers.services.sonarqube = {
      endpoints.http = {
        protocol = "http";
        address = "127.0.0.1";
        port = 9000;
        url = "http://127.0.0.1:9000";
      };
      units = lib.mkBefore [ "docker-sonarqube.service" ];
      containerPolicy = {
        secretReaders."sonarqube.properties" = [ "sonarqube" ];
        volumeOwners.sonarqube = [
          "sonarqube-data"
          "sonarqube-extensions"
          "sonarqube-logs"
        ];
      };
      images.sonarqube = {
        kind = "upstream";
        container = "sonarqube";
        inherit image repository digest;
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
      owner = "root";
      group = "root";
      # API 側の password は file 差替えで変わらないため自動 rotation は不可
      restartUnits = [ ];
    };
    sops.secrets."sonarqube/token" = {
      mode = "0400";
      owner = config.dotfiles.workstation.username;
      group = "users";
      restartUnits = [ "mcp-front-sonarqube.service" ];
    };
    sops.templates."sonarqube.properties" = {
      mode = "0440";
      owner = "root";
      group = "root";
      restartUnits = [ "docker-sonarqube.service" ];
      content = ''
        sonar.jdbc.url=jdbc:postgresql://sonarqube-db:5432/sonarqube
        sonar.jdbc.username=sonarqube
        sonar.jdbc.password=${config.sops.placeholder."sonarqube/db_password"}
        sonar.web.javaAdditionalOpts=-XX:-HeapDumpOnOutOfMemoryError -XX:ErrorFile=/dev/null
        sonar.ce.javaAdditionalOpts=-XX:-HeapDumpOnOutOfMemoryError -XX:ErrorFile=/dev/null
        # Elasticsearch の mandatory option と衝突するため ErrorFile の追加指定は不可
        sonar.search.javaAdditionalOpts=-XX:-HeapDumpOnOutOfMemoryError
      '';
    };

    virtualisation.oci-containers.containers = backend.containers;
    systemd.services = backend.systemdServices // {
      docker-sonarqube = backend.systemdServices.docker-sonarqube // {
        serviceConfig = backend.systemdServices.docker-sonarqube.serviceConfig // {
          TimeoutStopSec = lib.mkForce "75s";
        };
      };
    };
  };
}
