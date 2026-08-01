{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  containers = hostConfig.virtualisation.oci-containers.containers;

  # port の正本は publish 宣言。契約の URL がそこから外れていないかを見る
  publishedPort = builtins.elemAt (lib.splitString ":" (
    builtins.head (
      builtins.filter (
        option: builtins.match "127\\.0\\.0\\.1:[0-9]+:[0-9]+" option != null
      ) containers.sonarqube.extraOptions
    )
  )) 1;
  serverEnv = hostConfig.sops.templates."sonarqube.env";
in
{
  # server と DB が同じ password を見て、DB port は host へ出さない
  sonarqube-topology =
    assert containers.sonarqube.environmentFiles == [ serverEnv.path ];
    assert
      containers.sonarqube-db.environmentFiles == [ hostConfig.sops.templates."sonarqube-db.env".path ];
    assert lib.elem "--network=dotfiles-backends" containers.sonarqube.extraOptions;
    assert lib.elem "--network=dotfiles-backends" containers.sonarqube-db.extraOptions;
    assert lib.elem "SONARQUBE_URL=http://127.0.0.1:${publishedPort}"
      hostConfig.systemd.services.sonarqube-provision.serviceConfig.Environment;
    assert !(lib.elem "-p" containers.sonarqube-db.extraOptions);
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

      grep -Fqx "SONAR_JDBC_URL=jdbc:postgresql://sonarqube-db:5432/sonarqube" "$server"
      test "$(grep '^SONAR_JDBC_PASSWORD=' "$server" | cut -d= -f2-)" \
        = "$(grep '^POSTGRES_PASSWORD=' "$database" | cut -d= -f2-)"
      test "$(grep '^SONAR_JDBC_USERNAME=' "$server" | cut -d= -f2-)" \
        = "$(grep '^POSTGRES_USER=' "$database" | cut -d= -f2-)"
      touch $out
    '';
}
