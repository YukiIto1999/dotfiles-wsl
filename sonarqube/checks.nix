{
  pkgs,
  lib,
  self,
  hostConfig,
  ...
}:

let
  containers = hostConfig.virtualisation.oci-containers.containers;

  inherit (import "${self}/mcp/impl/exec-tokens.nix" { inherit lib; }) valuesOf;
  inherit (import "${self}/images/impl/container-argv.nix" { inherit lib hostConfig self; })
    containerArgv
    ;
  argvOf = name: containerArgv.${name};

  # port の正本は argv。extraOptions は docker が受け取る列ではない
  serverPublish = valuesOf (argvOf "sonarqube") "-p";
  publishedPort = builtins.elemAt (lib.splitString ":" (builtins.head serverPublish)) 1;
  serverEnv = hostConfig.sops.templates."sonarqube.env";
in
{
  # server と DB が同じ password を見て、DB port は host へ出さない
  sonarqube-topology =
    assert containers.sonarqube.environmentFiles == [ serverEnv.path ];
    assert
      containers.sonarqube-db.environmentFiles == [ hostConfig.sops.templates."sonarqube-db.env".path ];
    assert valuesOf (argvOf "sonarqube") "--network" == [ "dotfiles-backends" ];
    assert valuesOf (argvOf "sonarqube-db") "--network" == [ "dotfiles-backends" ];
    assert lib.elem "SONARQUBE_URL=http://127.0.0.1:${publishedPort}"
      hostConfig.systemd.services.sonarqube-provision.serviceConfig.Environment;
    assert builtins.length serverPublish == 1;
    assert valuesOf (argvOf "sonarqube-db") "-p" == [ ];
    assert lib.elem "docker-sonarqube-db.service" hostConfig.systemd.services.docker-sonarqube.requires;
    # 既定の admin 資格情報のまま公開しない
    assert lib.elem "docker-sonarqube.service" hostConfig.systemd.services.sonarqube-provision.requires;
    assert lib.elem "SONARQUBE_ADMIN_PASSWORD_FILE=${
      hostConfig.sops.secrets."sonarqube/admin_password".path
    }" hostConfig.systemd.services.sonarqube-provision.serviceConfig.Environment;
    pkgs.runCommandLocal "check-sonarqube-topology" { } ''
      set -eu

      server=${pkgs.writeText "sonarqube.env" serverEnv.content}
      database=${pkgs.writeText "sonarqube-db.env" hostConfig.sops.templates."sonarqube-db.env".content}

      printf '%s\n' SONAR_JDBC_URL SONAR_JDBC_USERNAME SONAR_JDBC_PASSWORD \
        SONAR_ES_BOOTSTRAP_CHECKS_DISABLE | sort > expected-server
      cut -d= -f1 "$server" | sort > actual-server
      diff -u expected-server actual-server

      printf '%s\n' POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD | sort > expected-database
      cut -d= -f1 "$database" | sort > actual-database
      diff -u expected-database actual-database

      grep -Fqx "SONAR_JDBC_URL=jdbc:postgresql://sonarqube-db:5432/sonarqube" "$server"
      test "$(grep '^SONAR_JDBC_PASSWORD=' "$server" | cut -d= -f2-)" \
        = "$(grep '^POSTGRES_PASSWORD=' "$database" | cut -d= -f2-)"
      test "$(grep '^SONAR_JDBC_USERNAME=' "$server" | cut -d= -f2-)" \
        = "$(grep '^POSTGRES_USER=' "$database" | cut -d= -f2-)"
      touch $out
    '';
}
