{
  config,
  lib,
  pkgs,
  ...
}:

let
  myCfg = config.dotfiles;
  cfg = config.dotfiles.platform.containers;
  mkCommand = import ../cli/impl/mk-command.nix { inherit config lib pkgs; };
  portBindings = import ./impl/port-bindings.nix { inherit lib; };
  configuredContainers = config.virtualisation.oci-containers.containers;
  observationTimeoutSeconds = 10;
  restartWarningCount = 5;
  restartFailureCount = 20;

  buildArtifactGcContract =
    let
      name = "docker-build-artifact-gc";
      dockerService = "docker.service";
      docker = lib.getExe pkgs.docker;
      reservedSpace = "10GB";
      unsharedMaxUsedSpace = "30GB";
      maxUsedSpace = "100GB";
      staleKeepDuration = "1440h";
    in
    rec {
      inherit name;
      serviceUnit = "${name}.service";
      timerUnit = "${name}.timer";
      daemonGc = {
        enabled = true;
        policy = [
          {
            keepDuration = staleKeepDuration;
            inherit reservedSpace;
            maxUsedSpace = unsharedMaxUsedSpace;
          }
          {
            inherit reservedSpace;
            maxUsedSpace = unsharedMaxUsedSpace;
          }
          {
            all = true;
            inherit reservedSpace maxUsedSpace;
          }
        ];
      };
      service = {
        after = [ dockerService ];
        wants = [ dockerService ];
        conditionPathExists = "/var/run/docker.sock";
        type = "oneshot";
        execStart = map lib.escapeShellArgs [
          [
            docker
            "image"
            "prune"
            "--force"
          ]
          [
            docker
            "buildx"
            "prune"
            "--force"
            "--all"
            "--max-used-space"
            maxUsedSpace
            "--reserved-space"
            reservedSpace
          ]
        ];
      };
      timer = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 00/6:00:00";
          Persistent = true;
          Unit = serviceUnit;
        };
      };
      observation = {
        kind = "systemd-timer";
        checkId = "maintenance/${timerUnit}";
        resourceKey = null;
        timeoutSeconds = observationTimeoutSeconds;
        failureMessage = "${timerUnit} or its service is not operational";
        timer = timerUnit;
        service = serviceUnit;
        unitFileStates = [
          "enabled"
          "enabled-runtime"
        ];
        activeStates = [ "active" ];
        serviceResults = [ "success" ];
      };
    };

  endpointType = lib.types.submodule {
    options = {
      protocol = lib.mkOption {
        type = lib.types.enum [
          "http"
          "tcp"
        ];
      };
      address = lib.mkOption { type = lib.types.str; };
      port = lib.mkOption { type = lib.types.port; };
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  };

  imageType = lib.types.submodule {
    options = {
      kind = lib.mkOption {
        type = lib.types.enum [
          "upstream"
          "nix"
        ];
        description = "image の取得責任。nix は imageFile、upstream は明示 sync が所有する。";
      };
      container = lib.mkOption {
        type = lib.types.str;
        description = "virtualisation.oci-containers.containers の attribute 名。";
      };
      image = lib.mkOption {
        type = lib.types.str;
        description = "docker run が使う canonical image reference。";
      };
      repository = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "upstream RepoDigest の repository。";
      };
      digest = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "upstream image の sha256 digest。";
      };
      imageFile = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Nix が生成し、OCI module が load する image archive。";
      };
    };
  };

  containerPolicyType = lib.types.submodule {
    options = {
      secretReaders = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        description = "secret template ごとに読み取りを許可する container 名";
      };
      volumeOwners = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        description = "container ごとに書き込みを許可する named volume";
      };
    };
  };

  serviceType = lib.types.submodule {
    options = {
      endpoints = lib.mkOption {
        type = lib.types.attrsOf endpointType;
      };
      units = lib.mkOption {
        type = lib.types.listOf lib.types.str;
      };
      images = lib.mkOption {
        type = lib.types.attrsOf imageType;
      };
      containerPolicy = lib.mkOption {
        type = containerPolicyType;
        default = { };
        description = "backend が所有する secret reader と named volume の許可契約";
      };
      health = lib.mkOption {
        type = lib.types.submodule {
          options = {
            endpoint = lib.mkOption { type = lib.types.str; };
            method = lib.mkOption {
              type = lib.types.enum [
                "GET"
                "POST"
              ];
            };
            path = lib.mkOption { type = lib.types.str; };
            timeout = lib.mkOption { type = lib.types.ints.positive; };
          };
        };
      };
    };
  };

  serviceEntries = lib.mapAttrsToList (application: service: {
    inherit application service;
  }) cfg.services;

  imageEntries = lib.concatMap (
    entry: lib.mapAttrsToList (_: image: { inherit image; }) entry.service.images
  ) serviceEntries;

  imageDefinitions = map (entry: entry.image) imageEntries;

  upstreamImages = map (image: image.image) (
    builtins.filter (image: image.kind == "upstream") imageDefinitions
  );

  syncImages = mkCommand {
    name = "dotfiles-sync-images";
    src = ./impl/sync-images.sh;
    runtimeInputs = with pkgs; [ coreutils ];
    vars = {
      dockerCommand = lib.escapeShellArg (lib.getExe pkgs.docker);
      upstreamImages = lib.escapeShellArg (lib.concatStringsSep " " upstreamImages);
    };
  };

  # 宣言へ固定する digest を registry から取る。sync は宣言済み digest しか見ない
  imageDigest = mkCommand {
    name = "dotfiles-image-digest";
    src = ./impl/image-digest.sh;
    runtimeInputs = with pkgs; [
      docker
      jq
    ];
  };

  publishedPortBindings = lib.concatMap portBindings.publishedPortBindings (
    builtins.attrValues configuredContainers
  );

  failedServices =
    predicate: map (entry: entry.application) (builtins.filter predicate serviceEntries);

  servicePortBindings =
    service:
    lib.concatMap (
      image:
      if builtins.hasAttr image.container configuredContainers then
        let
          container = configuredContainers.${image.container};
        in
        portBindings.publishedPortBindings container
      else
        [ ]
    ) (builtins.attrValues service.images);

  expectedPortBindings =
    service:
    map (endpoint: "${endpoint.address}:${toString endpoint.port}:${toString endpoint.port}") (
      builtins.attrValues service.endpoints
    );

  emptyContractServices = failedServices (
    entry:
    entry.service.endpoints == { }
    || entry.service.units == [ ]
    || entry.service.images == { }
    || lib.any (name: name == "") (builtins.attrNames entry.service.endpoints)
    || lib.any (name: name == "") (builtins.attrNames entry.service.images)
  );

  endpointDriftServices = failedServices (
    entry:
    let
      inherit (entry) service;
    in
    !lib.all (
      endpoint:
      endpoint.address != ""
      && endpoint.url == "${endpoint.protocol}://${endpoint.address}:${toString endpoint.port}"
    ) (builtins.attrValues service.endpoints)
    ||
      lib.sort builtins.lessThan (expectedPortBindings service)
      != lib.sort builtins.lessThan (servicePortBindings service)
  );

  unitDriftServices = failedServices (
    entry:
    let
      expectedUnits = map (image: "docker-${image.container}.service") (
        builtins.attrValues entry.service.images
      );
    in
    lib.sort builtins.lessThan entry.service.units != lib.sort builtins.lessThan expectedUnits
    || !lib.all (
      unit: builtins.hasAttr (lib.removeSuffix ".service" unit) config.systemd.services
    ) entry.service.units
  );

  healthDriftServices = failedServices (
    entry:
    let
      inherit (entry) service;
      inherit (service) health;
    in
    health.endpoint == ""
    || !builtins.hasAttr health.endpoint service.endpoints
    || service.endpoints.${health.endpoint}.protocol != "http"
    || health.path == ""
    || !lib.hasPrefix "/" health.path
  );

  containerObservations =
    let
      common = checkId: failureMessage: {
        inherit checkId failureMessage;
        resourceKey = null;
        timeoutSeconds = observationTimeoutSeconds;
      };
      mkEntry = name: value: { inherit name value; };
      serviceObservations = lib.concatMap (
        entry:
        map (
          unit:
          mkEntry "containers/service/${lib.removeSuffix ".service" unit}" (
            common "service/${unit}" "${unit} is not operational"
            // {
              kind = "systemd-service";
              inherit unit;
              loadStates = [ "loaded" ];
              activeStates = [ "active" ];
              results = [ "success" ];
            }
          )
        ) entry.service.units
      ) serviceEntries;
      serviceRestartObservations = lib.concatMap (
        entry:
        map (
          unit:
          mkEntry "containers/service-restart/${lib.removeSuffix ".service" unit}" (
            common "restart/service/${unit}" "could not observe restart count for ${unit}"
            // {
              kind = "restart-counter";
              sourceKind = "systemd-service";
              target = unit;
              warningAt = restartWarningCount;
              failureAt = restartFailureCount;
            }
          )
        ) entry.service.units
      ) serviceEntries;
      imageObservations = map (
        entry:
        let
          inherit (entry.image) container image;
        in
        mkEntry "containers/image/${container}" (
          common "container-image/${container}" "${container} is not running the declared image ${image}"
          // {
            kind = "container-image";
            inherit container image;
          }
        )
      ) imageEntries;
      healthObservations = map (
        entry:
        let
          inherit (entry) application service;
          inherit (service) health;
          url = "${service.endpoints.${health.endpoint}.url}${health.path}";
        in
        mkEntry "containers/health/${application}" {
          checkId = "container-health/${application}";
          resourceKey = null;
          timeoutSeconds = health.timeout;
          failureMessage = "${health.method} ${url} failed";
          kind = "http-health";
          inherit (health) method;
          inherit url;
        }
      ) serviceEntries;
    in
    builtins.listToAttrs (
      [
        (mkEntry "containers/roster" (
          common "container-roster" "container roster is empty"
          // {
            kind = "roster";
            members = map (entry: entry.image.container) imageEntries;
            minimumCount = 1;
            failureOnly = true;
          }
        ))
        (mkEntry "containers/build-artifact-gc" buildArtifactGcContract.observation)
      ]
      ++ serviceObservations
      ++ serviceRestartObservations
      ++ imageObservations
      ++ healthObservations
    );
in
{
  options.dotfiles.platform.containers = {
    enabled = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "この host に配備する container application の一覧。";
    };
    services = lib.mkOption {
      type = lib.types.attrsOf serviceType;
      default = { };
      internal = true;
      description = "Container application が公開する配備契約。";
    };
  };

  config = {
    dotfiles.platform.cli.commands = { inherit syncImages imageDigest; };
    dotfiles.health.observations = containerObservations;

    users.users.${myCfg.workstation.username}.extraGroups = [ "docker" ];

    virtualisation = {
      docker = {
        enable = true;
        daemon.settings.builder.gc = buildArtifactGcContract.daemonGc;
      };
      oci-containers.backend = "docker";
    };

    systemd.services.${buildArtifactGcContract.name} = {
      description = "Prune dangling Docker images and bounded BuildKit cache";
      inherit (buildArtifactGcContract.service) after wants;
      unitConfig.ConditionPathExists = buildArtifactGcContract.service.conditionPathExists;
      serviceConfig = {
        Type = buildArtifactGcContract.service.type;
        ExecStart = buildArtifactGcContract.service.execStart;
      };
    };

    systemd.timers.${buildArtifactGcContract.name} = {
      description = "Periodic Docker build artifact pruning";
      inherit (buildArtifactGcContract.timer) wantedBy timerConfig;
    };

    systemd.services.docker-dotfiles-backends-network = {
      description = "Docker network for backing services";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.docker}/bin/docker network inspect dotfiles-backends >/dev/null 2>&1 \
          || ${pkgs.docker}/bin/docker network create dotfiles-backends
      '';
    };

    assertions = [
      {
        assertion = serviceEntries != [ ] && emptyContractServices == [ ];
        message =
          "dotfiles.platform.containers services must have non-empty endpoints, units, and images: "
          + lib.concatStringsSep " " emptyContractServices;
      }
      {
        assertion = endpointDriftServices == [ ];
        message =
          "dotfiles.platform.containers endpoints must exactly match their URLs and OCI published ports: "
          + lib.concatStringsSep " " endpointDriftServices;
      }
      {
        assertion = unitDriftServices == [ ];
        message =
          "dotfiles.platform.containers units must exactly match their image-derived systemd services: "
          + lib.concatStringsSep " " unitDriftServices;
      }
      {
        assertion = healthDriftServices == [ ];
        message =
          "dotfiles.platform.containers health checks must name an HTTP endpoint and an absolute path: "
          + lib.concatStringsSep " " healthDriftServices;
      }
      {
        assertion = cfg.enabled == builtins.attrNames cfg.services;
        message = "dotfiles.platform.containers.enabled must exactly match the declared service keys";
      }
      {
        assertion =
          builtins.length (map (image: image.container) imageDefinitions)
          == builtins.length (lib.unique (map (image: image.container) imageDefinitions));
        message = "dotfiles.platform.containers image records must map to unique containers";
      }
      {
        assertion = lib.all (
          image:
          builtins.hasAttr image.container configuredContainers
          && configuredContainers.${image.container}.image == image.image
          && (configuredContainers.${image.container}.imageFile or null) == image.imageFile
          && configuredContainers.${image.container}.pull == "never"
        ) imageDefinitions;
        message = "dotfiles.platform.containers images must match the OCI image, imageFile, and pull policy";
      }
      {
        assertion =
          lib.sort builtins.lessThan (map (image: image.container) imageDefinitions)
          == lib.sort builtins.lessThan (builtins.attrNames configuredContainers);
        message = "dotfiles.platform.containers images must cover every deployed OCI container exactly once";
      }
      {
        assertion = lib.all (
          image:
          if image.kind == "upstream" then
            image.repository != null
            && image.repository != ""
            && image.digest != null
            && builtins.match "^sha256:[0-9a-f]{64}$" image.digest != null
            && (
              let
                parts = lib.splitString "@" image.image;
                reference = builtins.elemAt parts 0;
              in
              builtins.length parts == 2
              && builtins.elemAt parts 1 == image.digest
              && lib.hasPrefix "${image.repository}:" reference
              &&
                builtins.match "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$" (
                  lib.removePrefix "${image.repository}:" reference
                ) != null
            )
            && image.imageFile == null
          else
            image.repository == null && image.digest == null && image.imageFile != null
        ) imageDefinitions;
        message = "dotfiles.platform.containers images must use digest-locked upstream images or Nix imageFile sources";
      }
      {
        assertion = lib.all (container: container.pull == "never") (
          builtins.attrValues configuredContainers
        );
        message = "all OCI containers must disable implicit pulls";
      }
      {
        assertion = lib.all (
          binding: builtins.match "^127\\.0\\.0\\.1:[0-9]+:[0-9]+$" binding != null
        ) publishedPortBindings;
        message = "OCI container host ports must be published on loopback";
      }
    ];
  };
}
