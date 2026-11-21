{
  configuration = [
    (
      {
        helpers,
        pkgs,
        lib,
        hostConfig,
        hostOptions,
        mkProbeSystem,
        minimalCapabilityConfig,
        normalMachineModule,
        self,
        units,
        variantConfig,
        ...
      }:
      let
        expectedContract = builtins.fromJSON (builtins.readFile ./fixtures/target-contract.json);
        expectedProviders = expectedContract.enabledProviders;
        mcpOptions = hostOptions.dotfiles.platform.mcp;
        enabledProviders = hostConfig.dotfiles.platform.mcp.enabledProviders;
        frontsByName = hostConfig.dotfiles.platform.mcp.fronts;
        fronts = builtins.attrValues frontsByName;
        services = hostConfig.systemd.services;
        targets = hostConfig.dotfiles.platform.mcp.targets;
        variantTargets = variantConfig.dotfiles.platform.mcp.targets;
        configOf = front: services.${front.service}.serviceConfig;
        lifecycleOf = target: target.serverLifecycle or null;
        transportOf = target: target.serverTransport or null;
        sessionTargetNames = builtins.attrNames (
          lib.filterAttrs (_: target: lifecycleOf target == "session") targets
        );
        serviceTargetNames = builtins.attrNames (
          lib.filterAttrs (_: target: lifecycleOf target == "service") targets
        );
        stdioServiceTargetNames = builtins.attrNames (
          lib.filterAttrs (
            _: target: lifecycleOf target == "service" && transportOf target == "stdio"
          ) targets
        );
        streamableHttpTargetNames = builtins.attrNames (
          lib.filterAttrs (_: target: transportOf target == "streamable-http") targets
        );
        sessionPolicy = hostConfig.dotfiles.platform.mcp.sessionPolicy;
        sessionFixtureServer = pkgs.writeShellApplication {
          name = "mcp-session-state-fixture";
          text = ''
            exec ${lib.getExe pkgs.python3} ${./fixtures/session-state-server.py}
          '';
        };
        sessionFixtureExecStart = (pkgs.callPackage ./package/front-command.nix { }) {
          executable = lib.getExe sessionFixtureServer;
          serverLifecycle = "session";
          port = 18779;
          sessionPolicy = {
            idleSeconds = 1;
            frontGraceSeconds = 1;
          };
        };
        invalidLifecycleResult = builtins.tryEval (
          (pkgs.callPackage ./package/front-command.nix { }) {
            executable = lib.getExe sessionFixtureServer;
            serverLifecycle = "invalid";
            port = 18779;
            sessionPolicy = {
              idleSeconds = 1;
              frontGraceSeconds = 1;
            };
          }
        );
        sessionConfigOfExecStart =
          execStart: builtins.head (helpers.execTokens.valuesOf (helpers.execTokens.tokensOf execStart) "-f");
        sessionFrontConfigOf = name: sessionConfigOfExecStart (configOf frontsByName.${name}).ExecStart;
        sessionFixtureTokens = helpers.execTokens.tokensOf sessionFixtureExecStart;
        sessionFixtureFrontExecutable = builtins.head sessionFixtureTokens;
        sessionFixtureFrontConfig = sessionConfigOfExecStart sessionFixtureExecStart;
        lazySessionFixtureExecStart = (pkgs.callPackage ./package/front-command.nix { }) {
          executable = lib.getExe sessionFixtureServer;
          serverLifecycle = "session";
          lazyDiscovery = true;
          port = 18780;
          sessionPolicy = {
            idleSeconds = 1;
            frontGraceSeconds = 1;
          };
        };
        lazySessionFixtureFrontConfig = sessionConfigOfExecStart lazySessionFixtureExecStart;
        discoverySeeds = pkgs.callPackage ./package/discovery-seed.nix { };
        # module と同じ入力から同じ derivation を導き、front が参照する seed の取り違えを検出する
        expectedDiscoverySeedOf =
          name: target:
          if !target.lazyDiscovery then
            ""
          else if target.discoverySeed != null then
            discoverySeeds.committed {
              inherit name;
              seed = target.discoverySeed;
            }
          else
            discoverySeeds.capture {
              inherit name;
              inherit (target) executable;
            };
        # front と同じ fixture server を build sandbox で起動して作る seed と、live と食い違う tool 説明に変えた seed
        fixtureDiscoverySeed = discoverySeeds.capture {
          name = "session-state-fixture";
          executable = lib.getExe sessionFixtureServer;
        };
        driftedFixtureDiscoverySeed = "${pkgs.runCommandLocal "mcp-discovery-seed-drifted-fixture.json"
          { nativeBuildInputs = [ pkgs.jq ]; }
          ''
            jq '.protocols |= map_values(map(
              if .method == "tools/list" then .result.tools[0].description = "Drifted seed description." else . end
            ))' ${fixtureDiscoverySeed} >"$out"
          ''
        }";
        seededSessionFixtureConfig =
          seed: port:
          sessionConfigOfExecStart (
            (pkgs.callPackage ./package/front-command.nix { }) {
              executable = lib.getExe sessionFixtureServer;
              serverLifecycle = "session";
              lazyDiscovery = true;
              discoverySeed = seed;
              inherit port;
              sessionPolicy = {
                idleSeconds = 60;
                frontGraceSeconds = 1;
              };
            }
          );
        sessionFrontBehaviorInputs = with pkgs; [
          coreutils
          curl
          diffutils
          findutils
          gawk
          gnugrep
          gnused
          iproute2
          jq
        ];
        sessionFrontBehavior = pkgs.writeShellApplication {
          name = "mcp-session-front-behavior";
          runtimeInputs = sessionFrontBehaviorInputs;
          text = builtins.readFile ./fixtures/session-front-behavior.sh;
        };
        lazySessionFrontBehavior = pkgs.writeShellApplication {
          name = "mcp-lazy-session-front-behavior";
          runtimeInputs = sessionFrontBehaviorInputs;
          text = builtins.readFile ./fixtures/lazy-session-front-behavior.sh;
        };
        seededSessionFrontBehavior = pkgs.writeShellApplication {
          name = "mcp-seeded-session-front-behavior";
          runtimeInputs = sessionFrontBehaviorInputs;
          text = builtins.readFile ./fixtures/seeded-session-front-behavior.sh;
        };

        missingWaits = lib.concatMap (
          front:
          builtins.filter (
            unit: !(services ? ${lib.removeSuffix ".service" unit})
          ) targets.${front.name}.waitUnits
        ) fronts;

        inherit (helpers.execTokens)
          tokensOf
          onlyValue
          ;

        boundElsewhere = builtins.filter (
          front:
          let
            target = targets.${front.name};
            tokens = tokensOf (configOf front).ExecStart;
            port = toString front.port;
          in
          target.serverTransport == "stdio"
          && target.serverLifecycle == "service"
          && !(onlyValue tokens "--host" "127.0.0.1" && onlyValue tokens "--port" port)
        ) fronts;

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
        }) targets;

        subOptions =
          option: builtins.removeAttrs (option.type.nestedTypes.elemType.getSubOptions [ ]) [ "_module" ];
        targetOptions = subOptions mcpOptions.targets;
        probeOptions = builtins.removeAttrs (targetOptions.probe.type.getSubOptions [ ]) [ "_module" ];

        globalArgumentOwnership = import ./impl/global-argument-ownership.nix {
          inherit lib;
          inherit (helpers.unitOwnership) resolveUnitOwner;
        };
        evaluateInjection = module: lib.evalModules { modules = [ module ]; };
        directGlobalArgumentEvaluation = evaluateInjection ./fixtures/global-args/direct.nix;
        nestedGlobalArgumentEvaluation = evaluateInjection ./fixtures/global-args/nested.nix;
        importedGlobalArgumentEvaluation = evaluateInjection ./fixtures/global-args/importer.nix;
        nonMcpFixtureOwner = "health";
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
              id = "capabilities/synthetic-capability/adapter/mcp";
              path = "/fixture/capabilities/synthetic-capability/adapter/mcp";
            }
          ];
          definitions = [
            {
              file = "capabilities/orphan-capability/adapter/mcp/impl/injected.nix";
              value.frontBuilder = "unresolved-injection";
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
        bootTargetNames = builtins.filter (name: targets.${name}.activation == "boot") targetNames;
        gatewayService = hostConfig.dotfiles.platform.mcp.gateway.service;
        gatewayServiceObservation = "mcp/service/${gatewayService}";
        gatewayRestartObservation = "mcp/service-restart/${gatewayService}";
        firstTargetName = builtins.head targetNames;
        remainingTargets = builtins.removeAttrs targets [ firstTargetName ];
        remainingProviders = lib.unique (
          map (target: target.provider) (builtins.attrValues remainingTargets)
        );
        selectMcpObservations = lib.filterAttrs (name: _: lib.hasPrefix "mcp/" name);
        mcpObservations = selectMcpObservations hostConfig.dotfiles.health.observations;
        protocolObservation = mcpObservations."mcp/protocol/default" or null;
        commonObservation = checkId: failureMessage: {
          inherit checkId failureMessage;
          resourceKey = null;
          timeoutSeconds = observationTimeoutSeconds;
        };
        expectedMcpObservationsFor =
          configuration:
          let
            candidateTargets = configuration.dotfiles.platform.mcp.targets;
            candidateTargetNames = builtins.attrNames candidateTargets;
            candidateFronts = builtins.attrValues configuration.dotfiles.platform.mcp.fronts;
            candidateServiceNames = [
              configuration.dotfiles.platform.mcp.gateway.service
            ]
            ++ map (front: front.service) (
              builtins.filter (front: candidateTargets.${front.name}.activation == "boot") candidateFronts
            );
            candidateObservations = selectMcpObservations configuration.dotfiles.health.observations;
            candidateProtocol = candidateObservations."mcp/protocol/default" or null;
            probedTargetNames = builtins.filter (
              name: candidateTargets.${name}.exposure == "default" && !candidateTargets.${name}.lazyDiscovery
            ) candidateTargetNames;
            gatewayTimeout = lib.foldl' lib.max 0 (
              map (name: candidateTargets.${name}.probe.timeout) probedTargetNames
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
                    manager = "system";
                    inherit unit;
                    slice = configuration.dotfiles.workstation.workload.slices.support;
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
                    manager = "system";
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
              ++ map (name: "mcp-target/${name}") probedTargetNames;
              requiredOutcomeIds = [ "mcp-session" ];
              requiredResourceKeys = [ ];
              envelopeVersion = 1;
            };
          };
        expectedMcpObservations = expectedMcpObservationsFor hostConfig;
        observationContractMatches =
          configuration:
          (
            selectMcpObservations configuration.dotfiles.health.observations
            == expectedMcpObservationsFor configuration
          );
        removedObservationMutation = builtins.removeAttrs mcpObservations [
          gatewayServiceObservation
        ];
        changedObservationMutation = mcpObservations // {
          "${gatewayRestartObservation}" = mcpObservations.${gatewayRestartObservation} // {
            failureAt = restartFailureCount + 1;
          };
        };
        staleObservationMutation = mcpObservations // {
          "mcp/service/stale" = mcpObservations.${gatewayServiceObservation};
        };
        firstFrontService = (builtins.head fronts).service;
        extraTargetDescriptionVariantConfig =
          (mkProbeSystem [
            normalMachineModule
            {
              systemd.services.${hostConfig.dotfiles.platform.mcp.gateway.service}.description =
                lib.mkForce "Changed gateway description";
              systemd.services.${firstFrontService}.description = lib.mkForce "Changed front description";
              dotfiles.platform.mcp.targets.fixture = {
                provider = "fixture-provider";
                executable = "${pkgs.coreutils}/bin/true";
                serverLifecycle = "service";
                port = 8783;
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
          (mkProbeSystem [
            normalMachineModule
            {
              dotfiles.platform.mcp = {
                enabledProviders = lib.mkForce remainingProviders;
                targets = lib.mkForce remainingTargets;
              };
            }
          ]).config;
        timeout121Evaluation = builtins.tryEval (
          builtins.deepSeq
            (mkProbeSystem [
              normalMachineModule
              {
                dotfiles.platform.mcp.targets.${firstTargetName}.probe.timeout = lib.mkForce 121;
              }
            ]).config.dotfiles.platform.mcp.targets
            true
        );
        mcpObservationDefinitions = builtins.filter (
          definition: lib.hasPrefix "${self}/platform/mcp/" (toString definition.file)
        ) hostOptions.dotfiles.health.observations.definitionsWithLocations;
        mcpDefinitionKeys = lib.unique (
          lib.concatMap (definition: builtins.attrNames definition.value) mcpObservationDefinitions
        );

      in
      {
        mcp-runtime-observation-contract =
          assert builtins.length targetNames > 0;
          assert
            builtins.length (builtins.attrNames mcpObservations) == 2 * builtins.length bootTargetNames + 4;
          assert protocolObservation != null;
          assert mcpObservations == expectedMcpObservations;
          assert protocolObservation.command.meta.mainProgram == "dotfiles-mcp-gateway-observer";
          assert protocolObservation.command.dotfilesObservationCommandKind == "normalized-protocol";
          assert
            lib.getExe protocolObservation.command
            == "${lib.getBin protocolObservation.command}/bin/dotfiles-mcp-gateway-observer";
          assert removedObservationMutation != expectedMcpObservations;
          assert changedObservationMutation != expectedMcpObservations;
          assert staleObservationMutation != expectedMcpObservations;
          assert observationContractMatches extraTargetDescriptionVariantConfig;
          assert observationContractMatches removedTargetVariantConfig;
          assert
            builtins.length (
              builtins.attrNames (
                selectMcpObservations extraTargetDescriptionVariantConfig.dotfiles.health.observations
              )
            ) == 2 * (builtins.length bootTargetNames + 1) + 4;
          assert
            builtins.length (
              builtins.attrNames (selectMcpObservations removedTargetVariantConfig.dotfiles.health.observations)
            ) == 2 * (builtins.length bootTargetNames - 1) + 4;
          assert !timeout121Evaluation.success;
          assert mcpDefinitionKeys == builtins.attrNames expectedMcpObservations;
          assert lib.all (observation: observation.resourceKey == null) (builtins.attrValues mcpObservations);
          pkgs.runCommandLocal "check-mcp-runtime-observation-contract" { } "touch $out";

        mcp-provider-registry =
          let
            provided = lib.unique (map (target: target.provider) (builtins.attrValues targets));
            variantEnabled = variantConfig.dotfiles.platform.mcp.enabledProviders;
            variantProvided = lib.unique (map (target: target.provider) (builtins.attrValues variantTargets));
          in
          assert enabledProviders != [ ];
          assert provided != [ ];
          assert lib.sort builtins.lessThan enabledProviders == lib.sort builtins.lessThan provided;
          assert lib.sort builtins.lessThan variantEnabled == lib.sort builtins.lessThan variantProvided;
          pkgs.runCommandLocal "check-mcp-provider-registry" { } "touch $out";

        mcp-capability-gating =
          assert minimalCapabilityConfig.system.build.toplevel.drvPath != "";
          assert builtins.attrNames minimalCapabilityConfig.dotfiles.platform.mcp.targets == [ "memory" ];
          assert minimalCapabilityConfig.dotfiles.platform.mcp.enabledProviders == [ "memory" ];
          pkgs.runCommandLocal "check-mcp-capability-gating" { } "touch $out";

        mcp-target-contract =
          assert targetOptions.port.type.check 8770;
          assert targetOptions.port.type.check 8789;
          assert !(targetOptions.port.type.check 8769);
          assert !(targetOptions.port.type.check 8790);
          assert targetOptions.serverTransport.type.check "stdio";
          assert targetOptions.serverTransport.type.check "streamable-http";
          assert !(targetOptions.serverTransport.type.check "sse");
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
                executable = "${pkgs.coreutils}/bin/true-${name}";
              }
            ) expectedContract.targets;

            evaluateTargets =
              enabled: candidateTargets:
              lib.evalModules {
                specialArgs = { inherit pkgs; };
                modules = [
                  ./module.nix
                  (
                    { lib, ... }:
                    {
                      options = {
                        dotfiles = {
                          health.observations = lib.mkOption {
                            type = lib.types.attrsOf lib.types.raw;
                            default = { };
                          };
                          managedArtifacts = lib.mkOption {
                            type = lib.types.attrsOf lib.types.raw;
                            default = { };
                          };
                          workstation = {
                            username = lib.mkOption { type = lib.types.str; };
                            homeDir = lib.mkOption { type = lib.types.str; };
                          };
                        };
                        assertions = lib.mkOption {
                          type = lib.types.listOf lib.types.raw;
                          default = [ ];
                        };
                        systemd.services = lib.mkOption {
                          type = lib.types.attrsOf lib.types.raw;
                          default = { };
                        };
                        environment.etc = lib.mkOption {
                          type = lib.types.attrsOf lib.types.raw;
                          default = { };
                        };
                      };
                      config = {
                        dotfiles = {
                          workstation = {
                            username = "synthetic-user";
                            homeDir = "/home/synthetic-user";
                          };
                          platform.mcp = {
                            enabledProviders = enabled;
                            targets = candidateTargets;
                          };
                        };
                      };
                    }
                  )
                ];
              };
            assertionsPass =
              enabled: candidateTargets:
              let
                evaluation = evaluateTargets enabled candidateTargets;
                result = builtins.tryEval (
                  builtins.deepSeq evaluation.config.assertions (
                    lib.all (entry: entry.assertion) evaluation.config.assertions
                  )
                );
              in
              result.success && result.value;
            protectedTarget = builtins.head (builtins.attrNames expectedTargets);
            syntheticEvaluation = evaluateTargets expectedProviders expectedTargets;
            frontOverride = syntheticEvaluation.extendModules {
              modules = [
                {
                  dotfiles.platform.mcp.fronts.${protectedTarget}.url = lib.mkForce "http://external.invalid/mcp";
                }
              ];
            };
            probeOverride = syntheticEvaluation.extendModules {
              modules = [
                {
                  dotfiles.platform.mcp.targets.${protectedTarget}.probe.tool = lib.mkForce "external-probe";
                }
              ];
            };
            frontOverrideResult = builtins.tryEval (
              builtins.deepSeq frontOverride.config.dotfiles.platform.mcp.fronts.${protectedTarget}.url true
            );
            probeOverrideResult = builtins.tryEval (
              builtins.deepSeq probeOverride.config.dotfiles.platform.mcp.targets.${protectedTarget}.probe.tool
                true
            );

            renameTarget =
              from: to: candidateTargets:
              builtins.removeAttrs candidateTargets [ from ] // { "${to}" = candidateTargets.${from}; };
            updateTarget =
              name: update: candidateTargets:
              candidateTargets // { "${name}" = update candidateTargets.${name}; };

            missingProvider = updateTarget "session-adapter" (
              target: builtins.removeAttrs target [ "provider" ]
            ) expectedTargets;
            extraProvider = updateTarget "session-adapter" (
              target: target // { provider = "unlisted-provider"; }
            ) expectedTargets;
            underscoreId = renameTarget "session-adapter" "session_adapter" expectedTargets;
            prefixId = expectedTargets // {
              "stdio-adapter-child" = expectedTargets."stdio-adapter" // {
                port = 8783;
              };
            };
            duplicatePort = updateTarget "session-adapter" (
              target: target // { port = expectedTargets."stdio-adapter".port; }
            ) expectedTargets;
            executableWithArguments = updateTarget "session-adapter" (
              target: target // { executable = "/bin/true --verbose"; }
            ) expectedTargets;
            streamableSession = updateTarget "http-adapter" (
              target: target // { serverLifecycle = "session"; }
            ) expectedTargets;
            # 評価だけで内容を読まない、store 内の repository file
            committedSeed = ./fixtures/target-contract.json;
            lazySession = updateTarget "session-adapter" (
              target: builtins.removeAttrs target [ "probe" ] // { lazyDiscovery = true; }
            ) expectedTargets;
            lazySessionWithProbe = updateTarget "session-adapter" (
              target: target // { lazyDiscovery = true; }
            ) expectedTargets;
            committedLazySession = updateTarget "session-adapter" (
              target:
              builtins.removeAttrs target [ "probe" ]
              // {
                lazyDiscovery = true;
                discoverySeed = committedSeed;
              }
            ) expectedTargets;
            seedWithoutLazy = updateTarget "session-adapter" (
              target: target // { discoverySeed = committedSeed; }
            ) expectedTargets;
            seedOutsideStore = updateTarget "session-adapter" (
              target:
              builtins.removeAttrs target [ "probe" ]
              // {
                lazyDiscovery = true;
                discoverySeed = "/var/lib/discovery-seed.json";
              }
            ) expectedTargets;
            outsideSeedConfig = (evaluateTargets expectedProviders seedOutsideStore).config;
            outsideSeedEvaluation =
              builtins.tryEval
                outsideSeedConfig.dotfiles.platform.mcp.targets."session-adapter".discoverySeed;
            lazyDefault = updateTarget "session-adapter" (
              target:
              builtins.removeAttrs target [ "probe" ]
              // {
                exposure = "default";
                lazyDiscovery = true;
              }
            ) expectedTargets;
            lazyDefaultOutcomes =
              (evaluateTargets expectedProviders lazyDefault)
              .config.dotfiles.health.observations."mcp/protocol/default".allowedOutcomeIds;
            probelessSession = updateTarget "session-adapter" (
              target: builtins.removeAttrs target [ "probe" ]
            ) expectedTargets;
            probelessDefault = updateTarget "stdio-adapter" (
              target: builtins.removeAttrs target [ "probe" ]
            ) expectedTargets;
            lazyService = updateTarget "stdio-adapter" (
              target: target // { lazyDiscovery = true; }
            ) expectedTargets;
            lazyStreamableHttp = updateTarget "http-adapter" (
              target: target // { lazyDiscovery = true; }
            ) expectedTargets;

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
            dependencyFront = builtins.head (
              builtins.filter (front: targets.${front.name}.waitUnits != [ ]) fronts
            );
            dependencyService = dependencyFront.service;
            missingAfter = services // {
              "${dependencyService}" = services.${dependencyService} // {
                after = [ "network.target" ];
              };
            };
            missingRequires = services // {
              "${dependencyService}" = services.${dependencyService} // {
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
            sandboxedFront = builtins.head (
              builtins.filter (front: !targets.${front.name}.needsNetwork) fronts
            );
            sandboxedService = sandboxedFront.service;
            missingSandbox = services // {
              "${sandboxedService}" = services.${sandboxedService} // {
                serviceConfig = builtins.removeAttrs services.${sandboxedService}.serviceConfig [
                  "IPAddressDeny"
                ];
              };
            };
          in
          assert assertionsPass expectedProviders expectedTargets;
          assert !frontOverrideResult.success;
          assert !probeOverrideResult.success;
          assert !(assertionsPass [ ] expectedTargets);
          assert !(assertionsPass (expectedProviders ++ [ "session-provider" ]) expectedTargets);
          assert !(assertionsPass (lib.remove "session-provider" expectedProviders) expectedTargets);
          assert !(assertionsPass (expectedProviders ++ [ "unlisted-provider" ]) expectedTargets);
          assert !(assertionsPass expectedProviders missingProvider);
          assert !(assertionsPass expectedProviders extraProvider);
          assert !(assertionsPass expectedProviders underscoreId);
          assert !(assertionsPass expectedProviders prefixId);
          assert !(assertionsPass expectedProviders duplicatePort);
          assert !(assertionsPass expectedProviders executableWithArguments);
          assert dependenciesValid services;
          assert !(assertionsPass expectedProviders streamableSession);
          assert assertionsPass expectedProviders lazySession;
          assert !(assertionsPass expectedProviders lazySessionWithProbe);
          assert assertionsPass expectedProviders committedLazySession;
          assert !(assertionsPass expectedProviders seedWithoutLazy);
          assert !outsideSeedEvaluation.success;
          assert assertionsPass expectedProviders lazyDefault;
          assert
            lazyDefaultOutcomes == [
              "mcp-session"
              "mcp-tools"
              "mcp-target/stdio-adapter"
            ];
          assert assertionsPass expectedProviders probelessSession;
          assert !(assertionsPass expectedProviders probelessDefault);
          assert !(assertionsPass expectedProviders lazyService);
          assert !(assertionsPass expectedProviders lazyStreamableHttp);
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
              "platform/mcp/fixtures/global-args/direct.nix:_module.args.mkNpmMcp"
              "platform/mcp/fixtures/global-args/nested.nix:_module.args.mkMcpServer"
              "platform/mcp/fixtures/global-args/impl/injected.nix:_module.args.frontBuilder"
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
              "capabilities/orphan-capability/adapter/mcp/impl/injected.nix"
            ];
          assert
            unresolvedGlobalArgumentScan.scanIntegrityViolations == [
              "unresolved-scan:arguments=1,resolved=0"
              "unresolved-definitions=capabilities/orphan-capability/adapter/mcp/impl/injected.nix"
            ];
          assert actualGlobalArgumentDefinitions == [ ];
          assert actualGlobalArgumentScan.violations == [ ];
          pkgs.runCommandLocal "check-mcp-source-boundary" { } "touch $out";

        mcp-front-session-lifecycle =
          assert
            sessionPolicy == {
              idleSeconds = 1800;
              frontGraceSeconds = 60;
            };
          assert
            lib.sort builtins.lessThan (sessionTargetNames ++ serviceTargetNames)
            == lib.sort builtins.lessThan targetNames;
          assert lib.intersectLists sessionTargetNames serviceTargetNames == [ ];
          assert lib.subtractLists serviceTargetNames streamableHttpTargetNames == [ ];
          assert
            lib.sort builtins.lessThan stdioServiceTargetNames
            == lib.sort builtins.lessThan (lib.subtractLists streamableHttpTargetNames serviceTargetNames);
          assert !invalidLifecycleResult.success;
          assert lib.all (target: target ? executable && lib.hasPrefix "/" target.executable) (
            builtins.attrValues targets
          );
          assert lib.all (target: !(target ? serve)) (builtins.attrValues targets);
          assert lib.all (
            name:
            helpers.execTokens.valuesOf (helpers.execTokens.tokensOf
              (configOf frontsByName.${name}).ExecStart
            ) "-f" != [ ]
          ) sessionTargetNames;
          assert lib.all (
            name:
            builtins.elem "--stateless" (helpers.execTokens.tokensOf (configOf frontsByName.${name}).ExecStart)
          ) stdioServiceTargetNames;
          assert lib.all (
            name: (configOf frontsByName.${name}).ExecStart == targets.${name}.executable
          ) streamableHttpTargetNames;
          pkgs.runCommandLocal "check-mcp-front-session-lifecycle" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
            set -euo pipefail

            ${lib.concatMapStringsSep "\n" (
              name:
              let
                target = targets.${name};
                sessionConfig = sessionFrontConfigOf name;
              in
              ''
                EXPECTED_EXECUTABLE=${lib.escapeShellArg target.executable} \
                EXPECTED_DISCOVERY_SEED=${lib.escapeShellArg (expectedDiscoverySeedOf name target)} yq -e '
                  .config.mcp.sessionTtl == "1860s"
                  and .config.adminAddr == "off"
                  and .config.statsAddr == "off"
                  and .config.readinessAddr == "off"
                  and (.binds | length) == 1
                  and .binds[0].address == "127.0.0.1"
                  and (.binds[0].listeners[0].routes[0].backends[0].mcp.targets | length) == 1
                  and .binds[0].listeners[0].routes[0].backends[0].mcp.targets[0].stdio.cmd == strenv(EXPECTED_EXECUTABLE)
                  and (.binds[0].listeners[0].routes[0].backends[0].mcp.targets[0].stdio.discovery_seed // "") == strenv(EXPECTED_DISCOVERY_SEED)
                ' ${sessionConfig} >/dev/null
              ''
            ) sessionTargetNames}
            touch $out
          '';

        mcp-session-front-behavior =
          pkgs.runCommandLocal "check-mcp-session-front-behavior"
            {
              MCP_SESSION_FRONT_EXECUTABLE = sessionFixtureFrontExecutable;
              MCP_SESSION_FRONT_CONFIG = sessionFixtureFrontConfig;
            }
            ''
              ${lib.getExe sessionFrontBehavior}
              touch $out
            '';

        mcp-lazy-session-front-behavior =
          pkgs.runCommandLocal "check-mcp-lazy-session-front-behavior"
            {
              MCP_SESSION_FRONT_EXECUTABLE = sessionFixtureFrontExecutable;
              MCP_SESSION_FRONT_CONFIG = lazySessionFixtureFrontConfig;
              MCP_SESSION_FRONT_PORT = "18780";
            }
            ''
              ${lib.getExe lazySessionFrontBehavior}
              touch $out
            '';

        mcp-seeded-session-front-behavior =
          pkgs.runCommandLocal "check-mcp-seeded-session-front-behavior"
            {
              MCP_SESSION_FRONT_EXECUTABLE = sessionFixtureFrontExecutable;
              MCP_SEEDED_FRONT_CONFIG = seededSessionFixtureConfig fixtureDiscoverySeed 18781;
              MCP_SEEDED_FRONT_PORT = "18781";
              MCP_DRIFTED_FRONT_CONFIG = seededSessionFixtureConfig driftedFixtureDiscoverySeed 18782;
              MCP_DRIFTED_FRONT_PORT = "18782";
            }
            ''
              ${lib.getExe seededSessionFrontBehavior}
              touch $out
            '';

        mcp-front-contract =
          assert expectedFronts != { };
          assert frontsByName != { };
          assert fronts != [ ];
          assert frontsByName == expectedFronts;
          assert lib.all (front: (configOf front).RuntimeDirectory == front.runtimeDirectory) fronts;
          assert lib.all (front: (configOf front).RuntimeDirectoryMode == "0700") fronts;
          assert lib.all (front: (configOf front).User == hostConfig.dotfiles.workstation.username) fronts;
          assert lib.all (
            front: (configOf front).Environment == [ "HOME=${hostConfig.dotfiles.workstation.homeDir}" ]
          ) fronts;
          assert lib.all (front: (configOf front).MemoryMax == "2G") fronts;
          # user.slice 配下の root 所有 workload。system.slice の基盤と上限を分け合わない
          assert lib.all (
            front: (configOf front).Slice == hostConfig.dotfiles.workstation.workload.slices.support
          ) fronts;
          assert lib.all (front: (configOf front).Restart == "always") fronts;
          assert lib.all (front: (configOf front).RestartSec == "5s") fronts;
          assert lib.all (
            front:
            services.${front.service}.wantedBy
            == lib.optionals (targets.${front.name}.activation == "boot") [ "multi-user.target" ]
          ) fronts;
          assert missingWaits == [ ];
          assert boundElsewhere == [ ];
          assert unrestricted == [ ];
          assert overrestricted == [ ];
          assert dependencyDrift == [ ];
          pkgs.runCommandLocal "check-mcp-front-contract" { } "touch $out";

        # ExecStart の検査だけでは見逃す後段ラッパーの待ち受け先上書き
        mcp-front-wrapper-bind =
          let
            execs = map (
              name: services.${frontsByName.${name}.service}.serviceConfig.ExecStart
            ) stdioServiceTargetNames;
          in
          pkgs.runCommandLocal "check-mcp-front-wrapper-bind" { } ''
            inspected=0

            inspect() {
              [ "$(head -c 2 "$1")" = '#!' ] || return 0
              inspected=$((inspected + 1))
              norm=$(tr -d '"'"'"'"\\' < "$1")
              if printf '%s' "$norm" | grep -qE -- '--host|--port|--allowed-hosts|--output-dir|MCP_HTTP_HOST|MCP_HTTP_PORT'; then
                echo "front wrapper decides its own bind: $1"
                exit 1
              fi
              for next in $(printf '%s' "$norm" | sed -n 's/^ *exec \([^ ]*\).*/\1/p'); do
                case "$next" in /nix/store/*) [ -f "$next" ] && inspect "$next" ;; esac
              done
            }

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

        mcp-front-starts =
          let
            execs = map (
              name: services.${frontsByName.${name}.service}.serviceConfig.ExecStart
            ) serviceTargetNames;
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
              test "$started" -ge ${toString (builtins.length serviceTargetNames)}
              touch $out
            '';
      }
    )
  ];
}
