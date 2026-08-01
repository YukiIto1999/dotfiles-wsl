{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  contract = hostConfig.my.contract.sonarqube;
  containers = hostConfig.virtualisation.oci-containers.containers;
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
    assert lib.elem "127.0.0.1:${toString contract.ports.server}:${toString contract.ports.server}"
      containers.sonarqube.extraOptions;
    assert contract.url == "http://127.0.0.1:${toString contract.ports.server}";
    assert !(lib.elem "-p" containers.sonarqube-db.extraOptions);
    assert lib.elem "docker-sonarqube-db.service" hostConfig.systemd.services.docker-sonarqube.requires;
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
