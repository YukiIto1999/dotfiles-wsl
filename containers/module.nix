{
  config,
  lib,
  pkgs,
  ...
}:

let
  myCfg = config.dotfiles;
  cfg = config.dotfiles.containers;
  mkCommand = import ../commands/impl/mk-command.nix { inherit config lib pkgs; };
  configuredContainers = config.virtualisation.oci-containers.containers;

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

  imageDefinitions = lib.concatMap (service: builtins.attrValues service.images) (
    builtins.attrValues cfg.services
  );

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

  extraOptionPortBindings =
    container:
    let
      options = container.extraOptions;
    in
    lib.concatLists (
      lib.imap0 (
        index: option:
        if option == "-p" || option == "--publish" then
          [ (if index + 1 < builtins.length options then builtins.elemAt options (index + 1) else "") ]
        else if lib.hasPrefix "-p=" option then
          [ (lib.removePrefix "-p=" option) ]
        else if lib.hasPrefix "--publish=" option then
          [ (lib.removePrefix "--publish=" option) ]
        else
          [ ]
      ) options
    );

  publishedPortBindings = lib.concatMap (
    container: container.ports ++ extraOptionPortBindings container
  ) (builtins.attrValues configuredContainers);

  serviceEntries = lib.mapAttrsToList (name: service: {
    inherit name service;
  }) cfg.services;

  failedServices = predicate: map (entry: entry.name) (builtins.filter predicate serviceEntries);

  servicePortBindings =
    service:
    lib.concatMap (
      image:
      if builtins.hasAttr image.container configuredContainers then
        let
          container = configuredContainers.${image.container};
        in
        container.ports ++ extraOptionPortBindings container
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
in
{
  options.dotfiles.containers = {
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
    dotfiles.commands = { inherit syncImages imageDigest; };

    users.users.${myCfg.host.username}.extraGroups = [ "docker" ];

    virtualisation = {
      docker = {
        enable = true;
        daemon.settings.builder.gc = {
          enabled = true;
          defaultKeepStorage = "60GB";
        };
      };
      oci-containers.backend = "docker";
    };

    systemd.services.docker-buildkit-gc = {
      description = "Prune Docker BuildKit cache above the storage budget";
      after = [ "docker.service" ];
      wants = [ "docker.service" ];
      unitConfig.ConditionPathExists = "/var/run/docker.sock";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pkgs.docker} buildx prune --force --max-used-space 60GB --reserved-space 20GB";
      };
    };

    systemd.timers.docker-buildkit-gc = {
      description = "Periodic Docker BuildKit cache pruning";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 00/6:00:00";
        Persistent = true;
        Unit = "docker-buildkit-gc.service";
      };
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
          "dotfiles.containers services must have non-empty endpoints, units, and images: "
          + lib.concatStringsSep " " emptyContractServices;
      }
      {
        assertion = endpointDriftServices == [ ];
        message =
          "dotfiles.containers endpoints must exactly match their URLs and OCI published ports: "
          + lib.concatStringsSep " " endpointDriftServices;
      }
      {
        assertion = unitDriftServices == [ ];
        message =
          "dotfiles.containers units must exactly match their image-derived systemd services: "
          + lib.concatStringsSep " " unitDriftServices;
      }
      {
        assertion = healthDriftServices == [ ];
        message =
          "dotfiles.containers health checks must name an HTTP endpoint and an absolute path: "
          + lib.concatStringsSep " " healthDriftServices;
      }
      {
        assertion = cfg.enabled == builtins.attrNames cfg.services;
        message = "dotfiles.containers.enabled must exactly match the declared service keys";
      }
      {
        assertion =
          builtins.length (map (image: image.container) imageDefinitions)
          == builtins.length (lib.unique (map (image: image.container) imageDefinitions));
        message = "dotfiles.containers image records must map to unique containers";
      }
      {
        assertion = lib.all (
          image:
          builtins.hasAttr image.container configuredContainers
          && configuredContainers.${image.container}.image == image.image
          && (configuredContainers.${image.container}.imageFile or null) == image.imageFile
          && configuredContainers.${image.container}.pull == "never"
        ) imageDefinitions;
        message = "dotfiles.containers images must match the OCI image, imageFile, and pull policy";
      }
      {
        assertion =
          lib.sort builtins.lessThan (map (image: image.container) imageDefinitions)
          == lib.sort builtins.lessThan (builtins.attrNames configuredContainers);
        message = "dotfiles.containers images must cover every deployed OCI container exactly once";
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
        message = "dotfiles.containers images must use digest-locked upstream images or Nix imageFile sources";
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
      {
        assertion =
          builtins.hasAttr "sonarqube-db" configuredContainers
          && configuredContainers.sonarqube-db.ports == [ ]
          && extraOptionPortBindings configuredContainers.sonarqube-db == [ ];
        message = "the internal SonarQube database must not publish a host port";
      }
    ];
  };
}
