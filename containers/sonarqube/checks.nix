{
  lib,
  pkgs,
  hostConfig,
  hostOptions,
  ...
}:

let
  inherit (import ../impl/port-bindings.nix { inherit lib; }) publishedPortBindings;
  serverImage = "sonarqube:community@sha256:160bd2f6a3485bd09b655ef22dd63c02bd1fa7ba82aa5d9973fd010b8bcca0b3";
  databaseImage = "postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193";
  serverUnit = "docker-sonarqube.service";
  databaseUnit = "docker-sonarqube-db.service";
  adminPasswordFile = "/run/secrets/sonarqube/admin_password";
  databasePasswordFile = "/run/secrets/sonarqube/db_password";
  serverEnvironmentFile = "/run/secrets/rendered/sonarqube.env";
  databaseEnvironmentFile = "/run/secrets/rendered/sonarqube-db.env";

  expectedService = {
    endpoints.http = {
      protocol = "http";
      address = "127.0.0.1";
      port = 9000;
      url = "http://127.0.0.1:9000";
    };
    units = [
      serverUnit
      databaseUnit
    ];
    images = {
      sonarqube = {
        kind = "upstream";
        container = "sonarqube";
        image = serverImage;
        repository = "sonarqube";
        digest = "sha256:160bd2f6a3485bd09b655ef22dd63c02bd1fa7ba82aa5d9973fd010b8bcca0b3";
        imageFile = null;
      };
      sonarqube-db = {
        kind = "upstream";
        container = "sonarqube-db";
        image = databaseImage;
        repository = "postgres";
        digest = "sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193";
        imageFile = null;
      };
    };
    health = {
      endpoint = "http";
      method = "GET";
      path = "/api/system/status";
      timeout = 10;
    };
  };

  service = hostConfig.dotfiles.containers.services.sonarqube;
  server = hostConfig.virtualisation.oci-containers.containers.sonarqube;
  database = hostConfig.virtualisation.oci-containers.containers.sonarqube-db;
  serverSystemd = hostConfig.systemd.services.docker-sonarqube;
  databaseSystemd = hostConfig.systemd.services.docker-sonarqube-db;
  provision = hostConfig.systemd.services.sonarqube-provision;
  timer = hostConfig.systemd.timers.sonarqube-provision;
  adminSecret = hostConfig.sops.secrets."sonarqube/admin_password";
  databaseSecret = hostConfig.sops.secrets."sonarqube/db_password";
  serverTemplate = hostConfig.sops.templates."sonarqube.env";
  databaseTemplate = hostConfig.sops.templates."sonarqube-db.env";
  credentialOption = lib.attrByPath [
    "dotfiles"
    "containers"
    "sonarqube"
    "credentials"
    "adminPasswordFile"
  ] null hostOptions;
  publishedDatabaseBinding = "127.0.0.1:5432:5432";
  databasePortBindingMutations = [
    (database // { ports = [ publishedDatabaseBinding ]; })
    (
      database
      // {
        extraOptions = database.extraOptions ++ [
          "-p"
          publishedDatabaseBinding
        ];
      }
    )
    (
      database
      // {
        extraOptions = database.extraOptions ++ [
          "--publish"
          publishedDatabaseBinding
        ];
      }
    )
    (database // { extraOptions = database.extraOptions ++ [ "-p=${publishedDatabaseBinding}" ]; })
    (database // { extraOptions = database.extraOptions ++ [ "-p${publishedDatabaseBinding}" ]; })
    (
      database // { extraOptions = database.extraOptions ++ [ "--publish=${publishedDatabaseBinding}" ]; }
    )
    (database // { extraOptions = database.extraOptions ++ [ "-P" ]; })
    (database // { extraOptions = database.extraOptions ++ [ "--publish-all" ]; })
    (database // { extraOptions = database.extraOptions ++ [ "-P=true" ]; })
    (database // { extraOptions = database.extraOptions ++ [ "--publish-all=true" ]; })
    (database // { extraOptions = database.extraOptions ++ [ "--publish-all=invalid" ]; })
    (database // { extraOptions = database.extraOptions ++ [ "-iP" ]; })
    (database // { extraOptions = database.extraOptions ++ [ "-itp${publishedDatabaseBinding}" ]; })
    (database // { extraOptions = database.extraOptions ++ [ "-p" ]; })
  ];
  disabledPublishAllMutations = [
    (database // { extraOptions = database.extraOptions ++ [ "-P=false" ]; })
    (database // { extraOptions = database.extraOptions ++ [ "--publish-all=0" ]; })
  ];
  ownerAssertionDefinitions = builtins.filter (
    definition: lib.hasSuffix "/containers/sonarqube/module.nix" (toString definition.file)
  ) hostOptions.assertions.definitionsWithLocations;
  databasePortAssertions = builtins.filter (
    entry: entry.message == "the internal SonarQube database must not publish a host port"
  ) (lib.concatMap (definition: definition.value) ownerAssertionDefinitions);
in
{
  sonarqube-container =
    assert lib.assertMsg (
      credentialOption != null
    ) "SonarQube container owner must publish a typed adminPasswordFile contract";
    assert credentialOption.type.name == "str";
    assert credentialOption.readOnly or false;
    assert service == expectedService;
    assert server.image == serverImage;
    assert server.pull == "never";
    assert server.environmentFiles == [ serverEnvironmentFile ];
    assert
      server.volumes == [
        "sonarqube-data:/opt/sonarqube/data"
        "sonarqube-extensions:/opt/sonarqube/extensions"
        "sonarqube-logs:/opt/sonarqube/logs"
      ];
    assert
      server.extraOptions == [
        "--network=dotfiles-backends"
        "--memory=4g"
        "-p"
        "127.0.0.1:9000:9000"
      ];
    assert database.image == databaseImage;
    assert database.pull == "never";
    assert database.environmentFiles == [ databaseEnvironmentFile ];
    assert database.volumes == [ "sonarqube-db:/var/lib/postgresql/data" ];
    assert
      database.extraOptions == [
        "--network=dotfiles-backends"
        "--memory=1g"
      ];
    assert database.ports == [ ];
    assert builtins.length databasePortAssertions == 1;
    assert (builtins.head databasePortAssertions).assertion;
    assert publishedPortBindings database == [ ];
    assert
      map publishedPortBindings databasePortBindingMutations == [
        [ publishedDatabaseBinding ]
        [ publishedDatabaseBinding ]
        [ publishedDatabaseBinding ]
        [ publishedDatabaseBinding ]
        [ publishedDatabaseBinding ]
        [ publishedDatabaseBinding ]
        [ "<publish-all>" ]
        [ "<publish-all>" ]
        [ "<publish-all>" ]
        [ "<publish-all>" ]
        [ "<publish-all>" ]
        [ "<publish-option-cluster>" ]
        [ "<publish-option-cluster>" ]
        [ "" ]
      ];
    assert
      map publishedPortBindings disabledPublishAllMutations == [
        [ ]
        [ ]
      ];
    assert
      serverSystemd.requires == [
        "docker-dotfiles-backends-network.service"
        databaseUnit
      ];
    assert databaseSystemd.requires == [ "docker-dotfiles-backends-network.service" ];
    assert serverSystemd.serviceConfig.Restart == "always";
    assert serverSystemd.serviceConfig.RestartSec == "5s";
    assert databaseSystemd.serviceConfig.Restart == "always";
    assert databaseSystemd.serviceConfig.RestartSec == "5s";
    assert adminSecret.path == adminPasswordFile;
    assert adminSecret.mode == "0400";
    assert adminSecret.owner == "nixos";
    assert adminSecret.group == "users";
    assert adminSecret.restartUnits == [ ];
    assert databaseSecret.path == databasePasswordFile;
    assert databaseSecret.mode == "0400";
    assert databaseSecret.owner == "root";
    assert databaseSecret.group == "root";
    assert databaseSecret.restartUnits == [ ];
    assert serverTemplate.path == serverEnvironmentFile;
    assert serverTemplate.mode == "0400";
    assert serverTemplate.owner == "root";
    assert serverTemplate.group == "root";
    assert serverTemplate.restartUnits == [ serverUnit ];
    assert
      serverTemplate.content == ''
        SONAR_JDBC_URL=jdbc:postgresql://sonarqube-db:5432/sonarqube
        SONAR_JDBC_USERNAME=sonarqube
        SONAR_JDBC_PASSWORD=${hostConfig.sops.placeholder."sonarqube/db_password"}
        SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true
      '';
    assert databaseTemplate.path == databaseEnvironmentFile;
    assert databaseTemplate.mode == "0400";
    assert databaseTemplate.owner == "root";
    assert databaseTemplate.group == "root";
    assert databaseTemplate.restartUnits == [ databaseUnit ];
    assert
      databaseTemplate.content == ''
        POSTGRES_USER=sonarqube
        POSTGRES_PASSWORD=${hostConfig.sops.placeholder."sonarqube/db_password"}
        POSTGRES_DB=sonarqube
      '';
    assert provision.after == [ serverUnit ];
    assert provision.wants == [ serverUnit ];
    assert provision.requires == [ ];
    assert provision.wantedBy == [ ];
    assert provision.startLimitIntervalSec == 0;
    assert provision.serviceConfig.Type == "oneshot";
    assert !(provision.serviceConfig.RemainAfterExit or false);
    assert provision.serviceConfig.User == "nixos";
    assert provision.serviceConfig.Restart == "on-failure";
    assert provision.serviceConfig.RestartSec == "60s";
    assert
      provision.serviceConfig.Environment == [
        "SONARQUBE_URL=http://127.0.0.1:9000"
        "SONARQUBE_ADMIN_PASSWORD_FILE=${adminPasswordFile}"
      ];
    assert lib.hasSuffix "/bin/dotfiles-sonarqube-provision" provision.serviceConfig.ExecStart;
    assert timer.wantedBy == [ "timers.target" ];
    assert
      timer.timerConfig == {
        OnBootSec = "2min";
        OnUnitActiveSec = "1h";
      };
    assert hostConfig.dotfiles.containers.sonarqube.credentials.adminPasswordFile == adminPasswordFile;
    pkgs.runCommandLocal "check-sonarqube-container" { } "touch $out";
}
