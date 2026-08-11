{
  helpers,
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  mkNixosSystem,
  normalMachineModule,
  variantConfig,
  ...
}:

let
  inherit (helpers.execTokens) tokensOf;

  imageDefinitions = lib.concatMap (
    service:
    lib.mapAttrsToList (name: image: {
      inherit name image;
    }) service.images
  ) (builtins.attrValues hostConfig.dotfiles.containers.services);

  imageContractIsValid =
    definitions:
    definitions != [ ]
    && lib.all (
      entry:
      let
        inherit (entry) image;
      in
      image.container == entry.name
      && (
        if image.kind == "upstream" then
          image.repository != null
          && image.digest != null
          && lib.hasPrefix "sha256:" image.digest
          && lib.hasPrefix "${image.repository}:" image.image
          && lib.hasSuffix "@${image.digest}" image.image
        else
          image.imageFile != null && image.repository == null && image.digest == null
      )
    ) definitions;

  execRosterIsValid =
    scripts: containerNames:
    scripts != [ ]
    && containerNames != [ ]
    && builtins.length scripts == 3 * builtins.length containerNames;

  systemUnits = hostConfig.environment.etc."systemd/system".source;

  observationTimeoutSeconds = 10;
  restartWarningCount = 5;
  restartFailureCount = 20;

  selectContainerObservations = lib.filterAttrs (name: _: lib.hasPrefix "containers/" name);
  containerObservations = selectContainerObservations hostConfig.dotfiles.observations;
  containerRestartObservationKeys = builtins.filter (
    name: lib.hasPrefix "containers/container-restart/" name
  ) (builtins.attrNames containerObservations);

  expectedContainerObservationsFor =
    services:
    let
      serviceEntries = lib.mapAttrsToList (application: service: {
        inherit application service;
      }) services;
      imageEntries = lib.concatMap (
        entry: lib.mapAttrsToList (_: image: { inherit image; }) entry.service.images
      ) serviceEntries;
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
        (mkEntry "containers/buildkit-gc" (
          common "maintenance/docker-buildkit-gc.timer" "docker-buildkit-gc.timer or its service is not operational"
          // {
            kind = "systemd-timer";
            timer = "docker-buildkit-gc.timer";
            service = "docker-buildkit-gc.service";
            unitFileStates = [
              "enabled"
              "enabled-runtime"
            ];
            activeStates = [ "active" ];
            serviceResults = [ "success" ];
          }
        ))
      ]
      ++ serviceObservations
      ++ serviceRestartObservations
      ++ imageObservations
      ++ healthObservations
    );

  buildkitConfiguration = configuration: {
    daemonSettings = configuration.virtualisation.docker.daemon.settings;
    service = configuration.systemd.services.docker-buildkit-gc or null;
    timer = configuration.systemd.timers.docker-buildkit-gc or null;
  };

  containerContractMatches =
    configuration: services: observations:
    let
      expected = expectedContainerObservationsFor services;
      actual = selectContainerObservations observations;
      buildkit = buildkitConfiguration configuration;
      execTokens =
        if buildkit.service == null then [ ] else tokensOf buildkit.service.serviceConfig.ExecStart;
    in
    actual == expected
    && lib.attrByPath [ "builder" "gc" "enabled" ] null buildkit.daemonSettings == true
    && lib.attrByPath [ "builder" "gc" "defaultKeepStorage" ] null buildkit.daemonSettings == "60GB"
    && buildkit.service != null
    &&
      execTokens == [
        (lib.getExe pkgs.docker)
        "buildx"
        "prune"
        "--force"
        "--max-used-space"
        "60GB"
        "--reserved-space"
        "20GB"
      ]
    && buildkit.timer != null
    &&
      buildkit.timer.timerConfig == {
        OnCalendar = "*-*-* 00/6:00:00";
        Persistent = true;
        Unit = "docker-buildkit-gc.service";
      };

  expectedContainerObservations = expectedContainerObservationsFor hostConfig.dotfiles.containers.services;
  containerObservationKeys = builtins.attrNames expectedContainerObservations;
  containerObservationDefinitions = builtins.filter (
    definition: lib.hasSuffix "/containers/module.nix" (toString definition.file)
  ) hostOptions.dotfiles.observations.definitionsWithLocations;
  containerDefinitionKeys = lib.unique (
    lib.concatMap (definition: builtins.attrNames definition.value) containerObservationDefinitions
  );
  containerDefinitionKeysMatch = keys: keys == containerObservationKeys;
  uniqueNonNull =
    field: observations:
    let
      values = builtins.filter (value: value != null) (
        map (observation: observation.${field}) (builtins.attrValues observations)
      );
    in
    builtins.length values == builtins.length (lib.unique values);

  removeObservation = name: builtins.removeAttrs containerObservations [ name ];
  serviceRemovalMutation = removeObservation "containers/service/docker-agentmemory";
  serviceRestartRemovalMutation = removeObservation "containers/service-restart/docker-agentmemory";
  imageRemovalMutation = removeObservation "containers/image/agentmemory";
  healthRemovalMutation = removeObservation "containers/health/agentmemory";
  timerRemovalMutation = removeObservation "containers/buildkit-gc";
  rosterRemovalMutation = removeObservation "containers/roster";
  addStaleObservation =
    source: name:
    containerObservations
    // {
      ${name} = containerObservations.${source};
    };
  staleObservationMutations = [
    (addStaleObservation "containers/service/docker-agentmemory" "containers/service/stale")
    (addStaleObservation "containers/service-restart/docker-agentmemory" "containers/service-restart/stale")
    (addStaleObservation "containers/service-restart/docker-agentmemory" "containers/container-restart/agentmemory")
    (addStaleObservation "containers/image/agentmemory" "containers/image/stale")
    (addStaleObservation "containers/health/agentmemory" "containers/health/stale")
    (addStaleObservation "containers/roster" "containers/stale-roster")
    (addStaleObservation "containers/buildkit-gc" "containers/stale-buildkit-gc")
  ];
  maxStorageMutation = hostConfig // {
    virtualisation = hostConfig.virtualisation // {
      docker = hostConfig.virtualisation.docker // {
        daemon = hostConfig.virtualisation.docker.daemon // {
          settings = lib.recursiveUpdate hostConfig.virtualisation.docker.daemon.settings {
            builder.gc.defaultKeepStorage = "61GB";
          };
        };
      };
    };
    systemd = hostConfig.systemd // {
      services = hostConfig.systemd.services // {
        docker-buildkit-gc = hostConfig.systemd.services.docker-buildkit-gc // {
          serviceConfig = hostConfig.systemd.services.docker-buildkit-gc.serviceConfig // {
            ExecStart = "${lib.getExe pkgs.docker} buildx prune --force --max-used-space 61GB --reserved-space 20GB";
          };
        };
      };
    };
  };
  reservedStorageMutation = hostConfig // {
    systemd = hostConfig.systemd // {
      services = hostConfig.systemd.services // {
        docker-buildkit-gc = hostConfig.systemd.services.docker-buildkit-gc // {
          serviceConfig = hostConfig.systemd.services.docker-buildkit-gc.serviceConfig // {
            ExecStart = "${lib.getExe pkgs.docker} buildx prune --force --max-used-space 60GB --reserved-space 21GB";
          };
        };
      };
    };
  };

  additionalObservationVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      {
        dotfiles.observations."host/independent-container-observation" = {
          kind = "roster";
          members = [ "fixture" ];
          minimumCount = 1;
          failureOnly = false;
          checkId = null;
          resourceKey = null;
          timeoutSeconds = observationTimeoutSeconds;
          failureMessage = "independent foreign observation failed";
        };
      }
    ]).config;
  additionalContainerObservations = selectContainerObservations additionalObservationVariantConfig.dotfiles.observations;

  descriptionVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      (
        { lib, ... }:
        {
          systemd.services.docker-agentmemory.description = lib.mkForce "Descriptions must not select container observations";
          systemd.services.docker-buildkit-gc.description = lib.mkForce "Descriptions must not select the BuildKit GC observation";
        }
      )
    ]).config;
  descriptionVariantContainerObservations = selectContainerObservations descriptionVariantConfig.dotfiles.observations;

  fixtureRepository = "example.invalid/dotfiles-fixture";
  fixtureDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
  fixtureImage = "${fixtureRepository}:latest@${fixtureDigest}";
  extraContainerVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      (
        { lib, ... }:
        {
          dotfiles.containers = {
            enabled = lib.mkForce (
              lib.sort builtins.lessThan (hostConfig.dotfiles.containers.enabled ++ [ "fixture" ])
            );
            services.fixture = {
              endpoints.http = {
                protocol = "http";
                address = "127.0.0.1";
                port = 45678;
                url = "http://127.0.0.1:45678";
              };
              units = [ "docker-fixture.service" ];
              images.fixture = {
                kind = "upstream";
                container = "fixture";
                image = fixtureImage;
                repository = fixtureRepository;
                digest = fixtureDigest;
              };
              health = {
                endpoint = "http";
                method = "GET";
                path = "/health";
                timeout = 5;
              };
            };
          };
          virtualisation.oci-containers.containers.fixture = {
            image = fixtureImage;
            pull = "never";
            ports = [ "127.0.0.1:45678:45678" ];
          };
        }
      )
    ]).config;
  extraContainerObservations = selectContainerObservations extraContainerVariantConfig.dotfiles.observations;

  removedContainerServices = builtins.removeAttrs hostConfig.dotfiles.containers.services [
    "agentmemory"
  ];
  removedOciContainers = builtins.removeAttrs hostConfig.virtualisation.oci-containers.containers [
    "agentmemory"
  ];
  removedContainerVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      (
        { lib, ... }:
        {
          dotfiles.containers = {
            enabled = lib.mkForce (builtins.attrNames removedContainerServices);
            services = lib.mkForce removedContainerServices;
          };
          virtualisation.oci-containers.containers = lib.mkForce removedOciContainers;
        }
      )
    ]).config;
  removedContainerObservations = selectContainerObservations removedContainerVariantConfig.dotfiles.observations;
  removedAgentmemoryObservationKeys = [
    "containers/service/docker-agentmemory"
    "containers/service-restart/docker-agentmemory"
    "containers/image/agentmemory"
    "containers/health/agentmemory"
  ];
in
{
  docker-buildkit-gc-contract =
    let
      daemonSettings = hostConfig.virtualisation.docker.daemon.settings;
      gcService = hostConfig.systemd.services.docker-buildkit-gc or null;
      gcTimer = hostConfig.systemd.timers.docker-buildkit-gc or null;
      execTokens = if gcService == null then [ ] else tokensOf gcService.serviceConfig.ExecStart;
      dependencyFields = [
        "after"
        "before"
        "bindsTo"
        "conflicts"
        "joinsNamespaceOf"
        "onFailure"
        "onSuccess"
        "partOf"
        "propagatesReloadTo"
        "reloadPropagatedFrom"
        "requires"
        "requisite"
        "upholds"
        "wants"
      ];
      gcDependents = lib.concatLists (
        lib.mapAttrsToList (
          name: service:
          map (field: "${name}.${field}") (
            builtins.filter (
              field: lib.elem "docker-buildkit-gc.service" (service.${field} or [ ])
            ) dependencyFields
          )
        ) hostConfig.systemd.services
      );
    in
    assert lib.assertMsg (
      lib.attrByPath [ "builder" "gc" "enabled" ] null daemonSettings == true
    ) "Docker BuildKit GC must be enabled";
    assert lib.assertMsg (
      lib.attrByPath [ "builder" "gc" "defaultKeepStorage" ] null daemonSettings == "60GB"
    ) "Docker BuildKit GC must retain 60GB by default";
    assert lib.assertMsg (gcService != null) "Docker BuildKit GC service is missing";
    assert lib.assertMsg (
      gcService.after == [ "docker.service" ]
    ) "Docker BuildKit GC service must start after Docker: actual=${builtins.toJSON gcService.after}";
    assert lib.assertMsg (gcService.wants == [ "docker.service" ])
      "Docker BuildKit GC service must use a soft Docker dependency: actual=${builtins.toJSON gcService.wants}";
    assert lib.assertMsg (
      gcService.requires == [ ] && gcService.requiredBy == [ ]
    ) "Docker BuildKit GC failure must not propagate to Docker";
    assert lib.assertMsg (
      gcDependents == [ ]
    ) "system services must not depend on Docker BuildKit GC: actual=${builtins.toJSON gcDependents}";
    assert lib.assertMsg (
      gcService.serviceConfig.Type == "oneshot"
    ) "Docker BuildKit GC service must be oneshot";
    assert lib.assertMsg (
      gcService.unitConfig.ConditionPathExists == "/var/run/docker.sock"
    ) "Docker BuildKit GC service must require the Docker socket";
    assert lib.assertMsg (
      execTokens == [
        (lib.getExe pkgs.docker)
        "buildx"
        "prune"
        "--force"
        "--max-used-space"
        "60GB"
        "--reserved-space"
        "20GB"
      ]
    ) "Docker BuildKit GC command changed: actual=${builtins.toJSON execTokens}";
    assert lib.assertMsg (gcTimer != null) "Docker BuildKit GC timer is missing";
    assert lib.assertMsg (
      gcTimer.wantedBy == [ "timers.target" ]
    ) "Docker BuildKit GC timer must be enabled: actual=${builtins.toJSON gcTimer.wantedBy}";
    assert lib.assertMsg (
      gcTimer.timerConfig == {
        OnCalendar = "*-*-* 00/6:00:00";
        Persistent = true;
        Unit = "docker-buildkit-gc.service";
      }
    ) "Docker BuildKit GC timer must run persistently every six hours";
    assert lib.assertMsg (containerContractMatches hostConfig hostConfig.dotfiles.containers.services
      hostConfig.dotfiles.observations
    ) "Docker BuildKit GC settings and runtime observation must share one contract";
    assert lib.assertMsg (
      !(containerContractMatches maxStorageMutation hostConfig.dotfiles.containers.services
        containerObservations
      )
    ) "Docker BuildKit GC max storage mutation escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches reservedStorageMutation hostConfig.dotfiles.containers.services
        containerObservations
      )
    ) "Docker BuildKit GC reserved storage mutation escaped the owner contract";
    pkgs.runCommandLocal "check-docker-buildkit-gc-contract"
      {
        nativeBuildInputs = [
          pkgs.findutils
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail

        if grep -HnE '^(After|Before|BindsTo|Conflicts|JoinsNamespaceOf|OnFailure|OnSuccess|PartOf|PropagatesReloadTo|ReloadPropagatedFrom|Requires|Requisite|Upholds|Wants)=(.*[[:space:]])?docker-buildkit-gc\.service([[:space:]]|$)' ${systemUnits}/*.service > service-dependencies; then
          cat service-dependencies >&2
          exit 1
        fi

        find ${systemUnits} -mindepth 2 -type l -lname '*docker-buildkit-gc.service' -print > dependency-links
        if [ -s dependency-links ]; then
          cat dependency-links >&2
          exit 1
        fi

        touch $out
      '';

  container-runtime-observation-contract =
    assert lib.assertMsg (
      containerRestartObservationKeys == [ ]
    ) "Docker RestartCount observations must not duplicate systemd service restart observations";
    assert lib.assertMsg (
      containerObservations == expectedContainerObservations
    ) "container runtime observation registry is incomplete";
    assert lib.assertMsg (containerDefinitionKeysMatch containerDefinitionKeys)
      "container observation definition keys must match the owner contract";
    assert lib.assertMsg (
      !(containerDefinitionKeysMatch (containerDefinitionKeys ++ [ "containers/stale-definition" ]))
    ) "a stale container observation definition escaped the owner contract";
    assert lib.assertMsg (uniqueNonNull "checkId" containerObservations)
      "container runtime observation check IDs must be unique";
    assert lib.assertMsg (uniqueNonNull "resourceKey" containerObservations)
      "container runtime observation resource keys must be unique";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.containers.services
        serviceRemovalMutation
      )
    ) "container service observation removal escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.containers.services
        serviceRestartRemovalMutation
      )
    ) "container service restart observation removal escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.containers.services imageRemovalMutation)
    ) "container image observation removal escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.containers.services healthRemovalMutation)
    ) "container health observation removal escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.containers.services timerRemovalMutation)
    ) "BuildKit GC timer observation removal escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.containers.services rosterRemovalMutation)
    ) "container roster observation removal escaped the owner contract";
    assert lib.assertMsg (lib.all (
      observations:
      !(containerContractMatches hostConfig hostConfig.dotfiles.containers.services observations)
    ) staleObservationMutations) "stale container runtime observations escaped the owner contract";
    assert lib.assertMsg (
      containerContractMatches additionalObservationVariantConfig
        additionalObservationVariantConfig.dotfiles.containers.services
        additionalObservationVariantConfig.dotfiles.observations
      && additionalContainerObservations == expectedContainerObservations
      && builtins.hasAttr "host/independent-container-observation" additionalObservationVariantConfig.dotfiles.observations
    ) "a foreign observation changed the containers runtime contract";
    assert lib.assertMsg (
      descriptionVariantContainerObservations == containerObservations
    ) "service descriptions must not select container runtime observations";
    assert lib.assertMsg (
      containerContractMatches extraContainerVariantConfig
        extraContainerVariantConfig.dotfiles.containers.services
        extraContainerVariantConfig.dotfiles.observations
      && builtins.hasAttr "containers/image/fixture" extraContainerObservations
      && builtins.hasAttr "containers/health/fixture" extraContainerObservations
      && lib.elem "fixture" extraContainerObservations."containers/roster".members
    ) "a new container service was not projected into runtime observations";
    assert lib.assertMsg (
      containerContractMatches removedContainerVariantConfig
        removedContainerVariantConfig.dotfiles.containers.services
        removedContainerVariantConfig.dotfiles.observations
      &&
        removedContainerObservations
        == expectedContainerObservationsFor removedContainerVariantConfig.dotfiles.containers.services
      && builtins.all (
        name: !builtins.hasAttr name removedContainerObservations
      ) removedAgentmemoryObservationKeys
      && !lib.elem "agentmemory" removedContainerObservations."containers/roster".members
    ) "a removed container service remained in runtime observations";
    pkgs.runCommandLocal "check-container-runtime-observation-contract" { } "touch $out";

  container-backend-contract =
    let
      fixtures = [
        (import ./fixtures/container-backend.nix { inherit lib; })
        (import ./fixtures/container-backend-minimal.nix { inherit lib; })
      ];
      mkContainerBackend = import ./impl/container-backend.nix { inherit lib; };
      actual = map (fixture: mkContainerBackend fixture.name fixture.args) fixtures;
      expected = map (fixture: fixture.expected) fixtures;
    in
    assert lib.assertMsg (actual == expected) "container backend helper output changed";
    pkgs.runCommandLocal "check-container-backend-contract" { } "touch $out";

  container-application-roster =
    let
      required = [
        "agentmemory"
        "crawl4ai"
        "searxng"
        "sonarqube"
      ];
      provided = lib.sort builtins.lessThan (builtins.attrNames hostConfig.dotfiles.containers.services);
    in
    assert required != [ ];
    assert hostConfig.dotfiles.containers.enabled == required;
    assert provided == required;
    assert variantConfig.dotfiles.containers.enabled == required;
    assert
      lib.sort builtins.lessThan (builtins.attrNames variantConfig.dotfiles.containers.services)
      == required;
    pkgs.runCommandLocal "check-container-application-roster" { } "touch $out";

  # image は digest で固定し、参照が repository と digest に整合すること。
  # 宣言を写した期待値は宣言と写しの一致しか見ない
  oci-image-contract =
    assert imageDefinitions != [ ];
    assert imageContractIsValid imageDefinitions;
    assert !(imageContractIsValid [ ]);
    assert hostConfig.virtualisation.oci-containers.backend == "docker";
    assert hostConfig.virtualisation.docker.enable;
    # pull = never なので、宣言した image が事前に無いと container が起動しない
    assert lib.all (c: c.pull == "never") (
      builtins.attrValues hostConfig.virtualisation.oci-containers.containers
    );
    pkgs.runCommandLocal "check-oci-image-contract" { } "touch $out";

  container-argv-contract =
    assert lib.assertMsg (helpers.containerArgv.staleSecretReaders == [ ]) (
      "secret reader table names a template that does not exist: "
      + lib.concatStringsSep " " helpers.containerArgv.staleSecretReaders
    );
    assert lib.assertMsg (helpers.containerArgv.unexpectedTokens == [ ]) (
      "container run has tokens outside the allowed vocabulary: "
      + lib.concatStringsSep " " helpers.containerArgv.unexpectedTokens
    );
    assert lib.assertMsg (helpers.containerArgv.wrongValues == [ ]) (
      "container run passes a value outside its contract: "
      + lib.concatStringsSep " " helpers.containerArgv.wrongValues
    );
    assert lib.assertMsg (helpers.containerArgv.missingFlags == [ ]) (
      "container run omits a flag whose value must be checked: "
      + lib.concatStringsSep " " helpers.containerArgv.missingFlags
    );
    assert lib.assertMsg (helpers.containerArgv.strayExec == [ ]) (
      "container unit has Exec* outside the generated set: "
      + lib.concatStringsSep " " helpers.containerArgv.strayExec
    );
    assert lib.assertMsg (helpers.containerArgv.sharedVolumes == [ ]) (
      "named volume is mounted by more than one container: "
      + lib.concatStringsSep " " helpers.containerArgv.sharedVolumes
    );
    pkgs.runCommandLocal "check-container-argv-contract" { } "touch $out";

  # Exec* の key 集合だけでは、生成された script の中身までは見えない
  container-exec-content =
    let
      containerNames = builtins.attrNames hostConfig.virtualisation.oci-containers.containers;
      scripts = helpers.containerArgv.execScripts;
    in
    assert execRosterIsValid scripts containerNames;
    assert !(execRosterIsValid [ ] containerNames);
    assert !(execRosterIsValid [ ] [ ]);
    pkgs.runCommandLocal "check-container-exec-content" { } ''
      inspected=0
      for script in ${lib.escapeShellArgs scripts}; do
        inspected=$((inspected + 1))
        [ "$(head -c 2 "$script")" = '#!' ] || { echo "not a script: $script"; exit 1; }
        if grep -nE '(docker|podman)[^ ]* run ' "$script"; then
          echo "container is started outside ExecStart: $script"
          exit 1
        fi
      done
      test "$inspected" -eq ${toString (builtins.length scripts)}
      # 生成された Exec* は container ごとに ExecStart 以外が三つ。転記せず数から導く
      test "$inspected" -eq ${toString (3 * builtins.length containerNames)}
      touch $out
    '';
}
