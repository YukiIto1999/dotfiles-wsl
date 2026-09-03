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
  ) (builtins.attrValues hostConfig.dotfiles.platform.containers.services);

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

  expectedBuildArtifactGc =
    let
      name = "docker-build-artifact-gc";
      serviceUnit = "${name}.service";
      timerUnit = "${name}.timer";
    in
    {
      inherit name serviceUnit timerUnit;
      daemonGc = {
        enabled = true;
        policy = [
          {
            keepDuration = "1440h";
            maxUsedSpace = "30GB";
            reservedSpace = "10GB";
          }
          {
            maxUsedSpace = "30GB";
            reservedSpace = "10GB";
          }
          {
            all = true;
            maxUsedSpace = "100GB";
            reservedSpace = "10GB";
          }
        ];
      };
      execStartTokens = [
        [
          (lib.getExe pkgs.docker)
          "image"
          "prune"
          "--force"
        ]
        [
          (lib.getExe pkgs.docker)
          "buildx"
          "prune"
          "--force"
          "--all"
          "--max-used-space"
          "100GB"
          "--reserved-space"
          "10GB"
        ]
      ];
      timerConfig = {
        OnCalendar = "*-*-* 00/6:00:00";
        Persistent = true;
        Unit = serviceUnit;
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

  selectContainerObservations = lib.filterAttrs (name: _: lib.hasPrefix "containers/" name);
  containerObservations = selectContainerObservations hostConfig.dotfiles.health.observations;
  sampleApplication = builtins.head (
    builtins.attrNames hostConfig.dotfiles.platform.containers.services
  );
  sampleService = hostConfig.dotfiles.platform.containers.services.${sampleApplication};
  sampleUnit = builtins.head sampleService.units;
  sampleSystemdService = lib.removeSuffix ".service" sampleUnit;
  sampleContainerNames = map (image: image.container) (builtins.attrValues sampleService.images);
  sampleContainer = builtins.head sampleContainerNames;
  sampleObservationKeys = {
    service = "containers/service/${sampleSystemdService}";
    serviceRestart = "containers/service-restart/${sampleSystemdService}";
    image = "containers/image/${sampleContainer}";
    health = "containers/health/${sampleApplication}";
  };
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
        (mkEntry "containers/build-artifact-gc" expectedBuildArtifactGc.observation)
      ]
      ++ serviceObservations
      ++ serviceRestartObservations
      ++ imageObservations
      ++ healthObservations
    );

  buildArtifactGcConfiguration = configuration: {
    daemonSettings = configuration.virtualisation.docker.daemon.settings;
    service = configuration.systemd.services.${expectedBuildArtifactGc.name} or null;
    timer = configuration.systemd.timers.${expectedBuildArtifactGc.name} or null;
  };

  withBuildArtifactGcExecStart =
    configuration: execStart:
    configuration
    // {
      systemd = configuration.systemd // {
        services = configuration.systemd.services // {
          ${expectedBuildArtifactGc.name} =
            configuration.systemd.services.${expectedBuildArtifactGc.name}
            // {
              serviceConfig = configuration.systemd.services.${expectedBuildArtifactGc.name}.serviceConfig // {
                ExecStart = execStart;
              };
            };
        };
      };
    };

  containerContractMatches =
    configuration: services: observations:
    let
      expected = expectedContainerObservationsFor services;
      actual = selectContainerObservations observations;
      gc = buildArtifactGcConfiguration configuration;
      execStartTokens =
        if gc.service == null then [ ] else map tokensOf gc.service.serviceConfig.ExecStart;
    in
    actual == expected
    && lib.attrByPath [ "builder" "gc" ] null gc.daemonSettings == expectedBuildArtifactGc.daemonGc
    && gc.service != null
    && execStartTokens == expectedBuildArtifactGc.execStartTokens
    && gc.timer != null
    && gc.timer.timerConfig == expectedBuildArtifactGc.timerConfig;

  expectedContainerObservations = expectedContainerObservationsFor hostConfig.dotfiles.platform.containers.services;
  containerObservationKeys = builtins.attrNames expectedContainerObservations;
  containerObservationDefinitions = builtins.filter (
    definition: lib.hasSuffix "/platform/containers/module.nix" (toString definition.file)
  ) hostOptions.dotfiles.health.observations.definitionsWithLocations;
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
  serviceRemovalMutation = removeObservation sampleObservationKeys.service;
  serviceRestartRemovalMutation = removeObservation sampleObservationKeys.serviceRestart;
  imageRemovalMutation = removeObservation sampleObservationKeys.image;
  healthRemovalMutation = removeObservation sampleObservationKeys.health;
  timerRemovalMutation = removeObservation "containers/build-artifact-gc";
  rosterRemovalMutation = removeObservation "containers/roster";
  addStaleObservation =
    source: name:
    containerObservations
    // {
      ${name} = containerObservations.${source};
    };
  staleObservationMutations = [
    (addStaleObservation sampleObservationKeys.service "containers/service/stale")
    (addStaleObservation sampleObservationKeys.serviceRestart "containers/service-restart/stale")
    (addStaleObservation sampleObservationKeys.serviceRestart "containers/container-restart/stale")
    (addStaleObservation sampleObservationKeys.image "containers/image/stale")
    (addStaleObservation sampleObservationKeys.health "containers/health/stale")
    (addStaleObservation "containers/roster" "containers/stale-roster")
    (addStaleObservation "containers/build-artifact-gc" "containers/stale-build-artifact-gc")
  ];
  daemonPolicyMutation = hostConfig // {
    virtualisation = hostConfig.virtualisation // {
      docker = hostConfig.virtualisation.docker // {
        daemon = hostConfig.virtualisation.docker.daemon // {
          settings = lib.recursiveUpdate hostConfig.virtualisation.docker.daemon.settings {
            builder.gc.policy = [
              {
                keepDuration = "1439h";
                maxUsedSpace = "30GB";
                reservedSpace = "10GB";
              }
              {
                maxUsedSpace = "30GB";
                reservedSpace = "10GB";
              }
              {
                all = true;
                maxUsedSpace = "100GB";
                reservedSpace = "10GB";
              }
            ];
          };
        };
      };
    };
  };
  imagePruneMutation = withBuildArtifactGcExecStart hostConfig [
    (lib.escapeShellArgs (builtins.elemAt expectedBuildArtifactGc.execStartTokens 1))
  ];
  cacheBudgetMutation = withBuildArtifactGcExecStart hostConfig [
    (lib.escapeShellArgs (builtins.head expectedBuildArtifactGc.execStartTokens))
    "${lib.getExe pkgs.docker} buildx prune --force --all --max-used-space 101GB --reserved-space 10GB"
  ];

  additionalObservationVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      {
        dotfiles.health.observations."host/independent-container-observation" = {
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
  additionalContainerObservations = selectContainerObservations additionalObservationVariantConfig.dotfiles.health.observations;

  descriptionVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      (
        { lib, ... }:
        {
          systemd.services.${sampleSystemdService}.description =
            lib.mkForce "Descriptions must not select container observations";
          systemd.services.${expectedBuildArtifactGc.name}.description =
            lib.mkForce "Descriptions must not select the Docker build artifact GC observation";
        }
      )
    ]).config;
  descriptionVariantContainerObservations = selectContainerObservations descriptionVariantConfig.dotfiles.health.observations;

  fixtureRepository = "example.invalid/dotfiles-fixture";
  fixtureDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
  fixtureImage = "${fixtureRepository}:latest@${fixtureDigest}";
  extraContainerVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      (
        { lib, ... }:
        {
          dotfiles.platform.containers = {
            enabled = lib.mkForce (
              lib.sort builtins.lessThan (hostConfig.dotfiles.platform.containers.enabled ++ [ "fixture" ])
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
  extraContainerObservations = selectContainerObservations extraContainerVariantConfig.dotfiles.health.observations;

  removedContainerServices = builtins.removeAttrs hostConfig.dotfiles.platform.containers.services [
    sampleApplication
  ];
  removedOciContainers = builtins.removeAttrs hostConfig.virtualisation.oci-containers.containers sampleContainerNames;
  removedContainerVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      (
        { lib, ... }:
        {
          dotfiles.platform.containers = {
            enabled = lib.mkForce (builtins.attrNames removedContainerServices);
            services = lib.mkForce removedContainerServices;
          };
          virtualisation.oci-containers.containers = lib.mkForce removedOciContainers;
        }
      )
    ]).config;
  removedContainerObservations = selectContainerObservations removedContainerVariantConfig.dotfiles.health.observations;
  removedSampleObservationKeys =
    map (unit: "containers/service/${lib.removeSuffix ".service" unit}") sampleService.units
    ++ map (unit: "containers/service-restart/${lib.removeSuffix ".service" unit}") sampleService.units
    ++ map (container: "containers/image/${container}") sampleContainerNames
    ++ [ "containers/health/${sampleApplication}" ];
in
{
  docker-build-artifact-gc-contract =
    let
      gc = buildArtifactGcConfiguration hostConfig;
      actualDaemonGc = lib.attrByPath [ "builder" "gc" ] null gc.daemonSettings;
      execStartTokens =
        if gc.service == null then [ ] else map tokensOf gc.service.serviceConfig.ExecStart;
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
              field: lib.elem expectedBuildArtifactGc.serviceUnit (service.${field} or [ ])
            ) dependencyFields
          )
        ) hostConfig.systemd.services
      );
    in
    assert lib.assertMsg (
      actualDaemonGc == expectedBuildArtifactGc.daemonGc
    ) "Docker BuildKit GC policy changed: actual=${builtins.toJSON actualDaemonGc}";
    assert lib.assertMsg (gc.service != null) "Docker build artifact GC service is missing";
    assert lib.assertMsg (gc.service.after == [ "docker.service" ])
      "Docker build artifact GC service must start after Docker: actual=${builtins.toJSON gc.service.after}";
    assert lib.assertMsg (gc.service.wants == [ "docker.service" ])
      "Docker build artifact GC service must use a soft Docker dependency: actual=${builtins.toJSON gc.service.wants}";
    assert lib.assertMsg (
      gc.service.requires == [ ] && gc.service.requiredBy == [ ]
    ) "Docker build artifact GC failure must not propagate to Docker";
    assert lib.assertMsg (gcDependents == [ ])
      "system services must not depend on Docker build artifact GC: actual=${builtins.toJSON gcDependents}";
    assert lib.assertMsg (
      gc.service.serviceConfig.Type == "oneshot"
    ) "Docker build artifact GC service must be oneshot";
    assert lib.assertMsg (
      gc.service.unitConfig.ConditionPathExists == "/var/run/docker.sock"
    ) "Docker build artifact GC service must require the Docker socket";
    assert lib.assertMsg (
      execStartTokens == expectedBuildArtifactGc.execStartTokens
    ) "Docker build artifact GC commands changed: actual=${builtins.toJSON execStartTokens}";
    assert lib.assertMsg (gc.timer != null) "Docker build artifact GC timer is missing";
    assert lib.assertMsg (
      gc.timer.wantedBy == [ "timers.target" ]
    ) "Docker build artifact GC timer must be enabled: actual=${builtins.toJSON gc.timer.wantedBy}";
    assert lib.assertMsg (
      gc.timer.timerConfig == expectedBuildArtifactGc.timerConfig
    ) "Docker build artifact GC timer must run persistently every six hours";
    assert lib.assertMsg (containerContractMatches hostConfig
      hostConfig.dotfiles.platform.containers.services
      hostConfig.dotfiles.health.observations
    ) "Docker build artifact GC settings and runtime observation must share one contract";
    assert lib.assertMsg (
      !(containerContractMatches daemonPolicyMutation hostConfig.dotfiles.platform.containers.services
        containerObservations
      )
    ) "Docker BuildKit GC policy mutation escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches imagePruneMutation hostConfig.dotfiles.platform.containers.services
        containerObservations
      )
    ) "Docker dangling image prune mutation escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches cacheBudgetMutation hostConfig.dotfiles.platform.containers.services
        containerObservations
      )
    ) "Docker BuildKit cache budget mutation escaped the owner contract";
    pkgs.runCommandLocal "check-docker-build-artifact-gc-contract"
      {
        nativeBuildInputs = [
          pkgs.findutils
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail

        if grep -HnE '^(After|Before|BindsTo|Conflicts|JoinsNamespaceOf|OnFailure|OnSuccess|PartOf|PropagatesReloadTo|ReloadPropagatedFrom|Requires|Requisite|Upholds|Wants)=(.*[[:space:]])?docker-build-artifact-gc\.service([[:space:]]|$)' ${systemUnits}/*.service > service-dependencies; then
          cat service-dependencies >&2
          exit 1
        fi

        find ${systemUnits} -mindepth 2 -type l -lname '*docker-build-artifact-gc.service' -print > dependency-links
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
      !(containerContractMatches hostConfig hostConfig.dotfiles.platform.containers.services
        serviceRemovalMutation
      )
    ) "container service observation removal escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.platform.containers.services
        serviceRestartRemovalMutation
      )
    ) "container service restart observation removal escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.platform.containers.services
        imageRemovalMutation
      )
    ) "container image observation removal escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.platform.containers.services
        healthRemovalMutation
      )
    ) "container health observation removal escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.platform.containers.services
        timerRemovalMutation
      )
    ) "Docker build artifact GC timer observation removal escaped the owner contract";
    assert lib.assertMsg (
      !(containerContractMatches hostConfig hostConfig.dotfiles.platform.containers.services
        rosterRemovalMutation
      )
    ) "container roster observation removal escaped the owner contract";
    assert lib.assertMsg (lib.all (
      observations:
      !(containerContractMatches hostConfig hostConfig.dotfiles.platform.containers.services observations)
    ) staleObservationMutations) "stale container runtime observations escaped the owner contract";
    assert lib.assertMsg (
      containerContractMatches additionalObservationVariantConfig
        additionalObservationVariantConfig.dotfiles.platform.containers.services
        additionalObservationVariantConfig.dotfiles.health.observations
      && additionalContainerObservations == expectedContainerObservations
      && builtins.hasAttr "host/independent-container-observation" additionalObservationVariantConfig.dotfiles.health.observations
    ) "a foreign observation changed the containers runtime contract";
    assert lib.assertMsg (
      descriptionVariantContainerObservations == containerObservations
    ) "service descriptions must not select container runtime observations";
    assert lib.assertMsg (
      containerContractMatches extraContainerVariantConfig
        extraContainerVariantConfig.dotfiles.platform.containers.services
        extraContainerVariantConfig.dotfiles.health.observations
      && builtins.hasAttr "containers/image/fixture" extraContainerObservations
      && builtins.hasAttr "containers/health/fixture" extraContainerObservations
      && lib.elem "fixture" extraContainerObservations."containers/roster".members
    ) "a new container service was not projected into runtime observations";
    assert lib.assertMsg (
      containerContractMatches removedContainerVariantConfig
        removedContainerVariantConfig.dotfiles.platform.containers.services
        removedContainerVariantConfig.dotfiles.health.observations
      &&
        removedContainerObservations
        == expectedContainerObservationsFor removedContainerVariantConfig.dotfiles.platform.containers.services
      && builtins.all (
        name: !builtins.hasAttr name removedContainerObservations
      ) removedSampleObservationKeys
      && lib.all (
        container: !lib.elem container removedContainerObservations."containers/roster".members
      ) sampleContainerNames
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

  container-application-registry =
    let
      enabled = hostConfig.dotfiles.platform.containers.enabled;
      provided = builtins.attrNames hostConfig.dotfiles.platform.containers.services;
      variantEnabled = variantConfig.dotfiles.platform.containers.enabled;
      variantProvided = builtins.attrNames variantConfig.dotfiles.platform.containers.services;
    in
    assert enabled != [ ];
    assert enabled == provided;
    assert variantEnabled == variantProvided;
    pkgs.runCommandLocal "check-container-application-registry" { } "touch $out";

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
    let
      fixture = import ./fixtures/container-argv.nix { inherit lib pkgs; };
      evaluate =
        hostConfig:
        import ./impl/container-argv.nix {
          inherit lib hostConfig;
          inherit (helpers) execTokens;
        };
      valid = evaluate fixture.valid;
      missingSecretReader = evaluate fixture.missingSecretReader;
      missingVolumeOwner = evaluate fixture.missingVolumeOwner;
    in
    assert valid.secretReaders == fixture.expected.secretReaders;
    assert valid.volumeOwners == fixture.expected.volumeOwners;
    assert valid.wrongValues == [ ];
    assert
      missingSecretReader.wrongValues
      == [ "synthetic-backend:--env-file=/run/secrets/rendered/synthetic-secret.env" ];
    assert missingVolumeOwner.wrongValues == [ "synthetic-backend:-v=synthetic-state:/data" ];
    assert lib.assertMsg (helpers.containerArgv.staleSecretReaders == [ ]) (
      "secret reader table names a template that does not exist: "
      + lib.concatStringsSep " " helpers.containerArgv.staleSecretReaders
    );
    assert lib.assertMsg (helpers.containerArgv.stalePolicyContainers == [ ]) (
      "container policy names a container that does not exist: "
      + lib.concatStringsSep " " helpers.containerArgv.stalePolicyContainers
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
