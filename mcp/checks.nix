{
  helpers,
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  mkNixosSystem,
  normalMachineModule,
  self,
  units,
  variantConfig,
  ...
}:

let
  expectedContract = builtins.fromJSON (builtins.readFile ./fixtures/target-contract.json);
  expectedProviders = expectedContract.enabledProviders;
  mcpOptions = hostOptions.dotfiles.mcp;
  enabledProviders = hostConfig.dotfiles.mcp.enabledProviders;
  frontsByName = hostConfig.dotfiles.mcp.fronts;
  fronts = builtins.attrValues frontsByName;
  services = hostConfig.systemd.services;
  targets = hostConfig.dotfiles.mcp.targets;
  variantTargets = variantConfig.dotfiles.mcp.targets;
  configOf = front: services.${front.service}.serviceConfig;

  # typo した wait 先は systemd が黙って無視するので、宣言時に実在を確かめる
  missingWaits = lib.concatMap (
    front:
    builtins.filter (
      unit: !(services ? ${lib.removeSuffix ".service" unit})
    ) targets.${front.name}.waitUnits
  ) fronts;

  # front が loopback を外れると、firewall の無い WSL では外部から到達しうる。
  # 全 front が mcp-proxy の前段を通るので、bind 先は起動 command に現れる
  inherit (helpers.execTokens)
    tokensOf
    onlyValue
    ;

  boundElsewhere = builtins.filter (
    front:
    let
      tokens = tokensOf (configOf front).ExecStart;
      port = toString front.port;
    in
    !(onlyValue tokens "--host" "127.0.0.1" && onlyValue tokens "--port" port)
  ) fronts;

  expectedNetworkFronts = builtins.attrNames (
    lib.filterAttrs (_: target: target.needsNetwork) expectedContract.targets
  );

  actualNetworkFronts = lib.sort builtins.lessThan (
    builtins.attrNames (lib.filterAttrs (_: target: target.needsNetwork) targets)
  );

  # needsNetwork を宣言しない front は、通信が loopback へ限られていること
  unrestricted = builtins.filter (
    front:
    !targets.${front.name}.needsNetwork
    && (
      (configOf front).IPAddressDeny or null != "any"
      || (configOf front).IPAddressAllow or null != "localhost"
    )
  ) fronts;

  overrestricted = builtins.filter (
    front:
    targets.${front.name}.needsNetwork
    && (
      (configOf front).IPAddressDeny or null != null || (configOf front).IPAddressAllow or null != null
    )
  ) fronts;

  dependencyDrift = builtins.filter (
    front:
    let
      target = targets.${front.name};
      service = services.${front.service};
    in
    service.after != [ "network.target" ] ++ target.waitUnits || service.requires != target.waitUnits
  ) fronts;

  expectedFronts = lib.mapAttrs (name: target: {
    inherit name;
    inherit (target) port;
    service = "mcp-front-${name}";
    runtimeDirectory = "mcp-front-${name}";
    runtimeDirectoryPath = "/run/mcp-front-${name}";
    url = "http://127.0.0.1:${toString target.port}/mcp";
  }) expectedContract.targets;

  projectTargets = lib.mapAttrs (
    _: target: {
      inherit (target)
        needsNetwork
        port
        probe
        provider
        waitUnits
        ;
    }
  );
  targetContractMatches =
    candidateTargets: projectTargets candidateTargets == expectedContract.targets;

  subOptions =
    option: builtins.removeAttrs (option.type.nestedTypes.elemType.getSubOptions [ ]) [ "_module" ];
  targetOptions = subOptions mcpOptions.targets;
  probeOptions = builtins.removeAttrs (targetOptions.probe.type.getSubOptions [ ]) [ "_module" ];
  frontOptions = subOptions mcpOptions.fronts;
  optionMetadata = {
    enabledProviders = {
      type = mcpOptions.enabledProviders.type.name;
      elementType = mcpOptions.enabledProviders.type.nestedTypes.elemType.name;
      internal = mcpOptions.enabledProviders.internal or false;
      readOnly = mcpOptions.enabledProviders.readOnly or false;
      hasDefault = mcpOptions.enabledProviders ? default;
    };
    targets = {
      type = mcpOptions.targets.type.name;
      elementType = mcpOptions.targets.type.nestedTypes.elemType.name;
      internal = mcpOptions.targets.internal or false;
      readOnly = mcpOptions.targets.readOnly or false;
      hasDefault = mcpOptions.targets ? default;
      inherit (mcpOptions.targets) default;
      fields = builtins.mapAttrs (_: option: option.type.name) targetOptions;
      serveResultType = targetOptions.serve.type.nestedTypes.elemType.name;
      waitUnitsElementType = targetOptions.waitUnits.type.nestedTypes.elemType.name;
      probeReadOnly = targetOptions.probe.readOnly or false;
      probeFields = builtins.mapAttrs (_: option: option.type.name) probeOptions;
      needsNetworkDefault = targetOptions.needsNetwork.default;
      waitUnitsDefault = targetOptions.waitUnits.default;
    };
    fronts = {
      type = mcpOptions.fronts.type.name;
      elementType = mcpOptions.fronts.type.nestedTypes.elemType.name;
      internal = mcpOptions.fronts.internal or false;
      readOnly = mcpOptions.fronts.readOnly or false;
      hasDefault = mcpOptions.fronts ? default;
      fields = builtins.mapAttrs (_: option: option.type.name) frontOptions;
    };
    chromium = {
      type = mcpOptions.chromium.type.name;
      internal = mcpOptions.chromium.internal or false;
      readOnly = mcpOptions.chromium.readOnly or false;
      hasDefault = mcpOptions.chromium ? default;
    };
  };
  expectedOptionMetadata = {
    enabledProviders = {
      type = "listOf";
      elementType = "str";
      internal = false;
      readOnly = false;
      hasDefault = false;
    };
    targets = {
      type = "attrsOf";
      elementType = "submodule";
      internal = true;
      readOnly = false;
      hasDefault = true;
      default = { };
      fields = {
        provider = "str";
        port = "intBetween";
        serve = "functionTo";
        needsNetwork = "bool";
        waitUnits = "listOf";
        probe = "submodule";
      };
      serveResultType = "str";
      waitUnitsElementType = "str";
      probeReadOnly = true;
      probeFields = {
        tool = "str";
        args = "attrsOf";
        timeout = "intBetween";
      };
      needsNetworkDefault = false;
      waitUnitsDefault = [ ];
    };
    fronts = {
      type = "attrsOf";
      elementType = "submodule";
      internal = true;
      readOnly = true;
      hasDefault = false;
      fields = {
        name = "str";
        port = "unsignedInt16";
        url = "str";
        service = "str";
        runtimeDirectory = "str";
        runtimeDirectoryPath = "str";
      };
    };
    chromium = {
      type = "package";
      internal = true;
      readOnly = true;
      hasDefault = false;
    };
  };
  optionSchemaMatches = candidate: candidate == expectedOptionMetadata;

  globalArgumentOwnership = import ./impl/global-argument-ownership.nix {
    inherit lib;
    inherit (helpers.unitOwnership) resolveUnitOwner;
  };
  evaluateInjection = module: lib.evalModules { modules = [ module ]; };
  directGlobalArgumentEvaluation = evaluateInjection ./fixtures/global-args/direct.nix;
  nestedGlobalArgumentEvaluation = evaluateInjection ./fixtures/global-args/nested.nix;
  importedGlobalArgumentEvaluation = evaluateInjection ./codex/fixtures/global-args/importer.nix;
  nonMcpFixtureOwner = "commands";
  nonMcpGlobalArgumentEvaluation = evaluateInjection {
    _file = "${self}/${nonMcpFixtureOwner}/fixtures/non-mcp-global-argument.nix";
    config = lib.setAttrByPath [
      "_module"
      "args"
    ] { legitimateHelper = "legitimate-injection"; };
  };

  repositoryDefinitions =
    definitions:
    map (definition: {
      file = lib.removePrefix "${self}/" (toString definition.file);
      inherit (definition) value;
    }) (builtins.filter (definition: lib.hasPrefix "${self}/" (toString definition.file)) definitions);
  definitionsOf =
    evaluation: repositoryDefinitions evaluation.options._module.args.definitionsWithLocations;
  fixtureScan = globalArgumentOwnership.scan {
    inherit units;
    definitions = lib.concatMap definitionsOf [
      directGlobalArgumentEvaluation
      nestedGlobalArgumentEvaluation
      importedGlobalArgumentEvaluation
    ];
  };
  nonMcpFixtureScan = globalArgumentOwnership.scan {
    inherit units;
    definitions = definitionsOf nonMcpGlobalArgumentEvaluation;
  };
  emptyGlobalArgumentScan = globalArgumentOwnership.scan {
    units = [ ];
    definitions = [ ];
  };
  unresolvedGlobalArgumentScan = globalArgumentOwnership.scan {
    units = [
      {
        id = "mcp/codex";
        path = "/fixture/mcp/codex";
      }
    ];
    definitions = [
      {
        file = "mcp/orphan/impl/injected.nix";
        value.serveOverProxy = "unresolved-injection";
      }
    ];
  };
  actualGlobalArgumentDefinitions = repositoryDefinitions hostOptions._module.args.definitionsWithLocations;
  actualGlobalArgumentScan = globalArgumentOwnership.scan {
    inherit units;
    definitions = actualGlobalArgumentDefinitions;
  };

  observationTimeoutSeconds = 10;
  restartWarningCount = 5;
  restartFailureCount = 20;
  targetNames = builtins.attrNames targets;
  selectMcpObservations = lib.filterAttrs (name: _: lib.hasPrefix "mcp/" name);
  mcpObservations = selectMcpObservations hostConfig.dotfiles.observations;
  protocolObservation = mcpObservations."mcp/protocol/default" or null;
  commonObservation = checkId: failureMessage: {
    inherit checkId failureMessage;
    resourceKey = null;
    timeoutSeconds = observationTimeoutSeconds;
  };
  expectedMcpObservationsFor =
    configuration:
    let
      candidateTargets = configuration.dotfiles.mcp.targets;
      candidateTargetNames = builtins.attrNames candidateTargets;
      candidateFronts = builtins.attrValues configuration.dotfiles.mcp.fronts;
      candidateServiceNames = [
        configuration.dotfiles.mcp.gateway.service
      ]
      ++ map (front: front.service) candidateFronts;
      candidateObservations = selectMcpObservations configuration.dotfiles.observations;
      candidateProtocol = candidateObservations."mcp/protocol/default" or null;
      gatewayTimeout = lib.foldl' lib.max 0 (
        map (name: candidateTargets.${name}.probe.timeout) candidateTargetNames
      );
      serviceObservations = builtins.listToAttrs (
        map (
          service:
          let
            unit = "${service}.service";
          in
          lib.nameValuePair "mcp/service/${service}" (
            commonObservation "service/${service}" "${unit} is not operational"
            // {
              kind = "systemd-service";
              inherit unit;
              loadStates = [ "loaded" ];
              activeStates = [ "active" ];
              results = [ "success" ];
            }
          )
        ) candidateServiceNames
      );
      restartObservations = builtins.listToAttrs (
        map (
          service:
          let
            unit = "${service}.service";
          in
          lib.nameValuePair "mcp/service-restart/${service}" (
            commonObservation "restart/service/${service}" "could not observe restart count for ${unit}"
            // {
              kind = "restart-counter";
              sourceKind = "systemd-service";
              target = unit;
              warningAt = restartWarningCount;
              failureAt = restartFailureCount;
            }
          )
        ) candidateServiceNames
      );
    in
    serviceObservations
    // restartObservations
    // {
      "mcp/roster" = commonObservation "mcp-roster" "MCP target roster is empty" // {
        kind = "roster";
        members = candidateTargetNames;
        minimumCount = 1;
        failureOnly = true;
      };
      "mcp/protocol/default" = {
        kind = "normalized-protocol";
        checkId = "mcp-session";
        resourceKey = null;
        timeoutSeconds = 5 * gatewayTimeout;
        failureMessage = "MCP gateway protocol is not operational";
        command = if candidateProtocol == null then null else candidateProtocol.command;
        allowedOutcomeIds = [
          "mcp-session"
          "mcp-tools"
        ]
        ++ map (name: "mcp-target/${name}") candidateTargetNames;
        requiredOutcomeIds = [ "mcp-session" ];
        requiredResourceKeys = [ ];
        envelopeVersion = 1;
      };
    };
  expectedMcpObservations = expectedMcpObservationsFor hostConfig;
  observationContractMatches =
    configuration:
    (
      selectMcpObservations configuration.dotfiles.observations
      == expectedMcpObservationsFor configuration
    );
  removedObservationMutation = builtins.removeAttrs mcpObservations [
    "mcp/service/agentgateway-default"
  ];
  changedObservationMutation = mcpObservations // {
    "mcp/service-restart/agentgateway-default" =
      mcpObservations."mcp/service-restart/agentgateway-default"
      // {
        failureAt = restartFailureCount + 1;
      };
  };
  staleObservationMutation = mcpObservations // {
    "mcp/service/stale" = mcpObservations."mcp/service/agentgateway-default";
  };
  firstFrontService = (builtins.head fronts).service;
  descriptionVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      {
        systemd.services.${hostConfig.dotfiles.mcp.gateway.service}.description =
          lib.mkForce "Changed gateway description";
        systemd.services.${firstFrontService}.description = lib.mkForce "Changed front description";
      }
    ]).config;
  extraTargetVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      {
        dotfiles.mcp.targets.fixture = {
          provider = "memory";
          port = 8783;
          serve = port: "${pkgs.coreutils}/bin/true --host 127.0.0.1 --port ${toString port}";
          needsNetwork = false;
          waitUnits = [ ];
          probe = {
            tool = "fixture";
            args = { };
            timeout = 1;
          };
        };
      }
    ]).config;
  removedTargetVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      {
        dotfiles.mcp = {
          enabledProviders = lib.mkForce (lib.remove "playwright" enabledProviders);
          targets = lib.mkForce (builtins.removeAttrs targets [ "playwright" ]);
        };
      }
    ]).config;
  timeout121Evaluation = builtins.tryEval (
    builtins.deepSeq
      (mkNixosSystem [
        normalMachineModule
        {
          dotfiles.mcp.targets.codex.probe.timeout = lib.mkForce 121;
        }
      ]).config.dotfiles.mcp.targets
      true
  );
  mcpObservationDefinitions = builtins.filter (
    definition: lib.hasPrefix "${self}/mcp/" (toString definition.file)
  ) hostOptions.dotfiles.observations.definitionsWithLocations;
  mcpDefinitionKeys = lib.unique (
    lib.concatMap (definition: builtins.attrNames definition.value) mcpObservationDefinitions
  );

in
{
  mcp-runtime-observation-contract =
    assert builtins.length targetNames > 0;
    assert builtins.length (builtins.attrNames mcpObservations) == 2 * builtins.length targetNames + 4;
    assert protocolObservation != null;
    assert mcpObservations == expectedMcpObservations;
    assert protocolObservation.command.meta.mainProgram == "dotfiles-mcp-gateway-observer";
    assert protocolObservation.command.dotfilesObservationCommandKind == "normalized-protocol";
    assert
      protocolObservation.command.dotfilesObservationContract == {
        envelopeVersion = 1;
        inherit (protocolObservation)
          allowedOutcomeIds
          requiredOutcomeIds
          requiredResourceKeys
          ;
        gatewayTimeout = 120;
        outerTimeout = 600;
      };
    assert
      lib.getExe protocolObservation.command
      == "${lib.getBin protocolObservation.command}/bin/dotfiles-mcp-gateway-observer";
    assert removedObservationMutation != expectedMcpObservations;
    assert changedObservationMutation != expectedMcpObservations;
    assert staleObservationMutation != expectedMcpObservations;
    assert observationContractMatches descriptionVariantConfig;
    assert observationContractMatches extraTargetVariantConfig;
    assert observationContractMatches removedTargetVariantConfig;
    assert
      builtins.length (
        builtins.attrNames (selectMcpObservations extraTargetVariantConfig.dotfiles.observations)
      ) == 2 * (builtins.length targetNames + 1) + 4;
    assert
      builtins.length (
        builtins.attrNames (selectMcpObservations removedTargetVariantConfig.dotfiles.observations)
      ) == 2 * (builtins.length targetNames - 1) + 4;
    assert !timeout121Evaluation.success;
    assert mcpDefinitionKeys == builtins.attrNames expectedMcpObservations;
    assert lib.all (observation: observation.resourceKey == null) (builtins.attrValues mcpObservations);
    pkgs.runCommandLocal "check-mcp-runtime-observation-contract" { } "touch $out";

  mcp-provider-roster =
    let
      provided = lib.unique (map (target: target.provider) (builtins.attrValues targets));
      variantProvided = lib.unique (map (target: target.provider) (builtins.attrValues variantTargets));
    in
    assert expectedProviders != [ ];
    assert enabledProviders != [ ];
    assert provided != [ ];
    assert lib.sort builtins.lessThan enabledProviders == expectedProviders;
    assert lib.sort builtins.lessThan provided == expectedProviders;
    assert variantConfig.dotfiles.mcp.enabledProviders == expectedProviders;
    assert lib.sort builtins.lessThan variantProvided == expectedProviders;
    pkgs.runCommandLocal "check-mcp-provider-roster" { } "touch $out";

  mcp-target-contract =
    assert expectedContract.targets != { };
    assert targets != { };
    assert variantTargets != { };
    assert targetContractMatches targets;
    assert targetContractMatches variantTargets;
    assert !(targetContractMatches { });
    assert optionSchemaMatches optionMetadata;
    assert !(optionSchemaMatches (lib.recursiveUpdate optionMetadata { fronts.readOnly = false; }));
    assert !(optionSchemaMatches (lib.recursiveUpdate optionMetadata { chromium.readOnly = false; }));
    assert !(optionSchemaMatches (lib.recursiveUpdate optionMetadata { targets.type = "attrs"; }));
    assert targetOptions.port.type.check 8770;
    assert targetOptions.port.type.check 8789;
    assert !(targetOptions.port.type.check 8769);
    assert !(targetOptions.port.type.check 8790);
    assert probeOptions.args.type.nestedTypes.elemType.name == "anything";
    assert probeOptions.timeout.type.check 1;
    assert probeOptions.timeout.type.check 120;
    assert !(probeOptions.timeout.type.check 0);
    assert !(probeOptions.timeout.type.check 121);
    pkgs.runCommandLocal "check-mcp-target-contract" { } "touch $out";

  mcp-contract-mutations =
    let
      expectedTargets = lib.mapAttrs (
        name: target:
        target
        // {
          serve = port: "${name}:${toString port}";
        }
      ) expectedContract.targets;

      assertionsPass =
        enabled: candidateTargets:
        let
          evaluation = lib.evalModules {
            specialArgs = { inherit pkgs; };
            modules = [
              ./module.nix
              (
                { lib, ... }:
                {
                  options = {
                    dotfiles = {
                      observations = lib.mkOption {
                        type = lib.types.attrsOf lib.types.raw;
                        default = { };
                      };
                      host = {
                        username = lib.mkOption { type = lib.types.str; };
                        homeDir = lib.mkOption { type = lib.types.str; };
                      };
                      mcp.gateway.service = lib.mkOption { type = lib.types.str; };
                    };
                    assertions = lib.mkOption {
                      type = lib.types.listOf lib.types.raw;
                      default = [ ];
                    };
                    systemd.services = lib.mkOption {
                      type = lib.types.attrsOf lib.types.raw;
                      default = { };
                    };
                  };
                  config = {
                    dotfiles = {
                      host = {
                        username = "nixos";
                        homeDir = "/home/nixos";
                      };
                      mcp = {
                        enabledProviders = enabled;
                        gateway.service = "agentgateway-default";
                        targets = candidateTargets;
                      };
                    };
                  };
                }
              )
            ];
          };
          result = builtins.tryEval (
            builtins.deepSeq evaluation.config.assertions (
              lib.all (entry: entry.assertion) evaluation.config.assertions
            )
          );
        in
        result.success && result.value;

      renameTarget =
        from: to: candidateTargets:
        builtins.removeAttrs candidateTargets [ from ] // { "${to}" = candidateTargets.${from}; };
      updateTarget =
        name: update: candidateTargets:
        candidateTargets // { "${name}" = update candidateTargets.${name}; };

      missingProvider = updateTarget "memory" (
        target: builtins.removeAttrs target [ "provider" ]
      ) expectedTargets;
      extraProvider = updateTarget "memory" (target: target // { provider = "extra"; }) expectedTargets;
      underscoreId = renameTarget "memory" "memory_bad" expectedTargets;
      prefixId = expectedTargets // {
        "codex-child" = expectedTargets.codex // {
          port = 8783;
        };
      };
      duplicatePort = updateTarget "memory" (
        target: target // { port = expectedTargets.codex.port; }
      ) expectedTargets;
      probeDrift = updateTarget "memory" (
        target:
        target
        // {
          probe = target.probe // {
            tool = "memory_save";
          };
        }
      ) expectedTargets;
      networkDrift = updateTarget "searxng" (target: target // { needsNetwork = true; }) expectedTargets;

      dependenciesValid =
        candidateServices:
        lib.all (
          front:
          let
            target = targets.${front.name};
            service = candidateServices.${front.service};
          in
          service.after == [ "network.target" ] ++ target.waitUnits && service.requires == target.waitUnits
        ) fronts;
      crawl4aiService = frontsByName.crawl4ai.service;
      missingAfter = services // {
        "${crawl4aiService}" = services.${crawl4aiService} // {
          after = [ "network.target" ];
        };
      };
      missingRequires = services // {
        "${crawl4aiService}" = services.${crawl4aiService} // {
          requires = [ ];
        };
      };

      networkPolicyValid =
        candidateServices:
        lib.all (
          front:
          let
            target = targets.${front.name};
            serviceConfig = candidateServices.${front.service}.serviceConfig;
          in
          if target.needsNetwork then
            (serviceConfig.IPAddressDeny or null) == null && (serviceConfig.IPAddressAllow or null) == null
          else
            (serviceConfig.IPAddressDeny or null) == "any"
            && (serviceConfig.IPAddressAllow or null) == "localhost"
        ) fronts;
      searxngService = frontsByName.searxng.service;
      missingSandbox = services // {
        "${searxngService}" = services.${searxngService} // {
          serviceConfig = builtins.removeAttrs services.${searxngService}.serviceConfig [
            "IPAddressDeny"
          ];
        };
      };
    in
    assert assertionsPass expectedProviders expectedTargets;
    assert !(assertionsPass [ ] expectedTargets);
    assert !(assertionsPass (expectedProviders ++ [ "memory" ]) expectedTargets);
    assert !(assertionsPass (lib.remove "memory" expectedProviders) expectedTargets);
    assert !(assertionsPass (expectedProviders ++ [ "extra" ]) expectedTargets);
    assert !(assertionsPass expectedProviders missingProvider);
    assert !(assertionsPass expectedProviders extraProvider);
    assert !(assertionsPass expectedProviders underscoreId);
    assert !(assertionsPass expectedProviders prefixId);
    assert !(assertionsPass expectedProviders duplicatePort);
    assert targetContractMatches expectedTargets;
    assert !(targetContractMatches probeDrift);
    assert !(targetContractMatches networkDrift);
    assert dependenciesValid services;
    assert !(dependenciesValid missingAfter);
    assert !(dependenciesValid missingRequires);
    assert networkPolicyValid services;
    assert !(networkPolicyValid missingSandbox);
    pkgs.runCommandLocal "check-mcp-contract-mutations" { } "touch $out";

  mcp-source-boundary =
    assert fixtureScan.coverage.definitionCount == 3;
    assert fixtureScan.coverage.argumentCount == 3;
    assert fixtureScan.coverage.resolvedArgumentCount == 3;
    assert
      fixtureScan.violations == [
        "mcp/fixtures/global-args/direct.nix:_module.args.mkNpmMcp"
        "mcp/fixtures/global-args/nested.nix:_module.args.mkMcpServer"
        "mcp/codex/fixtures/global-args/impl/injected.nix:_module.args.serveOverProxy"
      ];
    assert nonMcpFixtureScan.diagnostics == [ ];
    assert nonMcpFixtureScan.violations == [ ];
    assert
      emptyGlobalArgumentScan.scanIntegrityViolations == [
        "empty-scan:units=0,definitions=0,arguments=0"
        "no-mcp-units"
      ];
    assert
      unresolvedGlobalArgumentScan.unresolvedDefinitionFiles == [
        "mcp/orphan/impl/injected.nix"
      ];
    assert
      unresolvedGlobalArgumentScan.scanIntegrityViolations == [
        "unresolved-scan:arguments=1,resolved=0"
        "unresolved-definitions=mcp/orphan/impl/injected.nix"
      ];
    assert actualGlobalArgumentDefinitions == [ ];
    assert actualGlobalArgumentScan.violations == [ ];
    pkgs.runCommandLocal "check-mcp-source-boundary" { } "touch $out";

  # front は宣言した port で loopback に listen し、書き込み領域を持つ
  mcp-front-contract =
    assert expectedFronts != { };
    assert frontsByName != { };
    assert fronts != [ ];
    assert builtins.attrNames targets == builtins.attrNames expectedContract.targets;
    assert frontsByName == expectedFronts;
    assert lib.all (front: (configOf front).RuntimeDirectory == front.runtimeDirectory) fronts;
    assert lib.all (front: (configOf front).RuntimeDirectoryMode == "0700") fronts;
    assert lib.all (front: (configOf front).User == hostConfig.dotfiles.host.username) fronts;
    assert lib.all (
      front: (configOf front).Environment == [ "HOME=${hostConfig.dotfiles.host.homeDir}" ]
    ) fronts;
    assert lib.all (front: (configOf front).MemoryMax == "2G") fronts;
    assert lib.all (front: (configOf front).Restart == "always") fronts;
    assert lib.all (front: (configOf front).RestartSec == "5s") fronts;
    assert lib.all (front: services.${front.service}.wantedBy == [ "multi-user.target" ]) fronts;
    assert missingWaits == [ ];
    assert boundElsewhere == [ ];
    assert unrestricted == [ ];
    assert overrestricted == [ ];
    assert dependencyDrift == [ ];
    assert actualNetworkFronts == expectedNetworkFronts;
    pkgs.runCommandLocal "check-mcp-front-contract" { } "touch $out";

  # unit の ExecStart しか見ないと、wrapper が後から bind を上書きできる。
  # binary は Nix から読めないので、shebang の判定は derivation の中で行う
  mcp-front-wrapper-bind =
    let
      execs = map (front: services.${front.service}.serviceConfig.ExecStart) fronts;
    in
    pkgs.runCommandLocal "check-mcp-front-wrapper-bind" { } ''
      inspected=0

      # 引用を外してから見る。--ho"st" は shell では --host に戻る
      inspect() {
        [ "$(head -c 2 "$1")" = '#!' ] || return 0
        inspected=$((inspected + 1))
        norm=$(tr -d '"'"'"'"\\' < "$1")
        if printf '%s' "$norm" | grep -qE -- '--host|--port|--allowed-hosts|--output-dir|MCP_HTTP_HOST|MCP_HTTP_PORT'; then
          echo "front wrapper decides its own bind: $1"
          exit 1
        fi
        # exec で辿り着く先も wrapper。一段の間接で消えないようにする
        for next in $(printf '%s' "$norm" | sed -n 's/^ *exec \([^ ]*\).*/\1/p'); do
          case "$next" in /nix/store/*) [ -f "$next" ] && inspect "$next" ;; esac
        done
      }

      # 総数を固定すると上流の packaging で壊れる。front ごとに一つ以上見る
      for exec in ${lib.escapeShellArgs execs}; do
        inspected=0
        for token in $exec; do
          case "$token" in /nix/store/*) ;; *) continue ;; esac
          [ -f "$token" ] || continue
          inspect "$token"
        done
        test "$inspected" -ge 1 || { echo "no wrapper inspected for: $exec"; exit 1; }
      done
      touch $out
    '';

  # 生成した wrapper が実際に起動するかは、宣言の整合では見えない。
  # exec の位置を誤ると起動せず、それでも 40 の check は緑を返す
  mcp-front-starts =
    let
      # stdio front は mcp-proxy に包まれる前の実体を直接起こす
      execs = map (front: services.${front.service}.serviceConfig.ExecStart) fronts;
    in
    pkgs.runCommandLocal "check-mcp-front-starts"
      {
        nativeBuildInputs = with pkgs; [
          coreutils
          gnugrep
          gnused
        ];
      }
      ''
        set -euo pipefail

        # 継続行を畳んでから見る。危険な書き方を数え上げても必ず漏れるので、
        # 「exec は唯一で、単純コマンドで、最後の実行文」という安全な形を要求する
        inspect() {
          script=$1
          ${pkgs.bash}/bin/bash -n "$script" || {
            echo "front wrapper is not valid shell: $script" >&2
            exit 1
          }

          logical=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$script" \
            | grep -vE '^[[:space:]]*(#|$)')

          count=$(printf '%s\n' "$logical" | grep -cE '^[[:space:]]*exec[[:space:]]' || true)
          if [ "$count" != 1 ]; then
            echo "front wrapper must exec exactly once, found $count: $script" >&2
            exit 1
          fi

          if ! printf '%s\n' "$logical" | tail -1 | grep -qE '^[[:space:]]*exec[[:space:]]'; then
            echo "front wrapper runs a command after exec: $script" >&2
            exit 1
          fi

          # 制御演算子を含めば単純コマンドではない。exec が条件に従属しうる
          if printf '%s\n' "$logical" | tail -1 | grep -qE '(&&|\|\||;|\||&)'; then
            echo "front wrapper conditions its exec: $script" >&2
            exit 1
          fi
        }

        started=0
        for exec in ${lib.escapeShellArgs execs}; do
          for token in $exec; do
            case "$token" in /nix/store/*) ;; *) continue ;; esac
            [ -f "$token" ] || continue
            [ "$(head -c 2 "$token")" = '#!' ] || continue
            inspect "$token"
            started=$((started + 1))
          done
        done
        test "$started" -ge ${toString (builtins.length fronts)}
        touch $out
      '';
}
