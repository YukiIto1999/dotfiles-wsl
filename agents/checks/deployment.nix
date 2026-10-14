{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        hostOptions,
        variantConfig,
        mkProbeSystem,
        minimalCapabilityConfig,
        projectMemoryDisabledConfig,
        normalMachineModule,
        self,
        ...
      }:

      let
        expected = builtins.fromJSON (builtins.readFile ../fixtures/client-contract.json);
        agentConfig = hostConfig.dotfiles.agents;
        inherit (agentConfig) clients;
        variantClients = variantConfig.dotfiles.agents.clients;
        homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.workstation.username};
        policySkills = lib.genAttrs hostConfig.dotfiles.skills.enabled (
          name: hostConfig.dotfiles.skills.registry.${name}
        );
        isReferenceOnlySkill = import ../impl/skill-discovery.nix { inherit lib; };
        artifacts = hostConfig.dotfiles.managedArtifacts;
        artifactSource = id: artifacts.${id}.source;
        gatewayUrl = hostConfig.dotfiles.platform.mcp.gateway.url;
        gatewayPort = hostConfig.dotfiles.platform.mcp.gateway.port;
        variantGatewayUrl = variantConfig.dotfiles.platform.mcp.gateway.url;
        roster = hostConfig.dotfiles.toolchain.lsp;
        installAgents = hostConfig.dotfiles.platform.cli.commands.installAgents;
        installAgentsExe = lib.getExe installAgents;
        atomicPublish = import ../impl/atomic-publish.nix { inherit pkgs; };
        restrictedAgentRules = projectMemoryDisabledConfig.dotfiles.agents.shared.rules;
        telemetryDisabledConfig =
          (mkProbeSystem [
            normalMachineModule
            { dotfiles.telemetry.enable = false; }
          ]).config;
        minimalCapabilitySkills = minimalCapabilityConfig.dotfiles.agents.shared.skills;
        transitiveCapabilityAgentConfig =
          (mkProbeSystem [
            normalMachineModule
            (
              { lib, ... }:
              {
                dotfiles.capabilities.enabled = lib.mkForce [ "browser-automation" ];
              }
            )
          ]).config;
        atomicPublishExe = lib.getExe' atomicPublish "dotfiles-agent-atomic-publish";

        losslessVersionArgs = [
          "trailing\n"
          "\n"
          "embedded\nline"
          "  spaced  "
          "pipe|value"
        ];
        losslessInstallManifest = builtins.toJSON [
          {
            name = "lossless-fixture";
            binary = "argv-capture";
            versionArgs = losslessVersionArgs;
            install = {
              kind = "installer-script";
              updateOwner = "upstream-installer";
              layout = "upstream-managed";
              scriptUrl = "https://example.invalid/install.sh";
            };
          }
        ];
        losslessInstallerCurl = pkgs.writeShellScriptBin "curl" ''
          exit 0
        '';
        losslessInstallAgents = pkgs.writeShellApplication {
          name = "check-lossless-install-agents";
          runtimeInputs = [
            atomicPublish
            losslessInstallerCurl
          ]
          ++ (with pkgs; [
            bash
            curl
            diffutils
            findutils
            gawk
            jq
            gnutar
            gzip
            coreutils
            util-linux
          ]);
          text =
            builtins.replaceStrings
              [
                "@atomicPublishCommand@"
                "@installManifest@"
                "@probeEnvironment@"
                "@transactionHookCommand@"
                "@versionArgsDecoder@"
              ]
              [
                (lib.escapeShellArg atomicPublishExe)
                losslessInstallManifest
                ""
                (lib.escapeShellArg "${pkgs.coreutils}/bin/true")
                (builtins.readFile ../impl/version-args.sh)
              ]
              (builtins.readFile ../impl/install-agents.sh);
        };
        losslessInstallAgentsExe = lib.getExe losslessInstallAgents;
        atomicPublishHookSupport = import ./support/atomic-publish-hook.nix {
          inherit pkgs;
        };
        inherit (atomicPublishHookSupport) atomicPublishTestHook;

        fixtureMigrateCodexConfig = pkgs.writeShellScript "fixture-migrate-codex-config" (
          builtins.replaceStrings
            [
              "@chmodCommand@"
              "@idCommand@"
              "@jqCommand@"
              "@mktempCommand@"
              "@mvCommand@"
              "@remarshalCommand@"
              "@rmCommand@"
              "@statCommand@"
            ]
            [
              "${pkgs.coreutils}/bin/chmod"
              "${pkgs.coreutils}/bin/id"
              (lib.getExe pkgs.jq)
              ''"$FIXTURE_MKTEMP"''
              "${pkgs.coreutils}/bin/mv"
              ''"$FIXTURE_REMARSHAL"''
              "${pkgs.coreutils}/bin/rm"
              ''"$FIXTURE_STAT"''
            ]
            (builtins.readFile ../clients/codex/impl/migrate-config.sh)
        );

        expectedInstallManifest = map (name: {
          inherit name;
          inherit (expected.clients.${name}) binary versionArgs install;
        }) expected.required;
        projectMemoryHookCommand =
          harness: name: "/run/current-system/sw/bin/dotfiles-memory hook --harness ${harness} ${name}";
        expectedHook =
          {
            harness,
            name,
            matcher ? null,
            extra ? { },
          }:
          [
            (
              {
                hooks = [
                  (
                    {
                      type = "command";
                      command = projectMemoryHookCommand harness name;
                    }
                    // extra
                  )
                ];
              }
              // lib.optionalAttrs (matcher != null) { inherit matcher; }
            )
          ];
        gateHook =
          {
            kind,
            matcher ? null,
          }:
          (
            {
              hooks = [
                {
                  type = "command";
                  command = "/run/current-system/sw/bin/dotfiles-agent-gate hook ${kind}";
                }
              ];
            }
            // lib.optionalAttrs (matcher != null) { inherit matcher; }
          );
        expectedClaudeHooks = {
          SessionStart = expectedHook {
            harness = "claude";
            name = "session-start";
          };
          UserPromptSubmit = expectedHook {
            harness = "claude";
            name = "prompt-submit";
          };
          PreToolUse = [
            (gateHook {
              kind = "edit";
              matcher = "Edit|Write|MultiEdit|NotebookEdit";
            })
            (gateHook {
              kind = "observe";
              matcher = "Bash";
            })
          ];
          PostToolUse = [
            (gateHook {
              kind = "arm";
              matcher = "Edit|Write|MultiEdit|NotebookEdit";
            })
            (gateHook {
              kind = "learn";
              matcher = "Read";
            })
            (gateHook {
              kind = "observe";
              matcher = "Bash";
            })
          ];
          PostToolUseFailure = [
            (gateHook {
              kind = "observe";
              matcher = "Bash";
            })
          ];
          Stop = [ (gateHook { kind = "stop"; }) ];
        };
        expectedCodexHooks = {
          SessionStart = expectedHook {
            harness = "codex";
            name = "session-start";
            extra.statusMessage = "project-memory: loading session context";
          };
          UserPromptSubmit = expectedHook {
            harness = "codex";
            name = "prompt-submit";
          };
        };

        managedRows = lib.concatMap (
          clientName:
          lib.mapAttrsToList (id: file: {
            inherit clientName id file;
          }) clients.${clientName}.managedFiles
        ) (builtins.attrNames clients);
        normalizeSource =
          source:
          if builtins.typeOf source == "path" then
            builtins.path {
              path = source;
              name = builtins.baseNameOf (toString source);
            }
          else
            source;
        managedDeploymentMatches =
          row:
          let
            artifact = artifacts."agents/${row.clientName}/${row.id}";
            target = row.file.destination;
            deployedSource = normalizeSource row.file.source;
          in
          artifact.source == deployedSource
          && (
            if row.file.deployment == "system" then
              hostConfig.environment.etc.${target}.source == deployedSource
              && artifact.deployedAt == "/etc/${target}"
            else if row.file.deployment == "home" then
              homeConfig.home.file.${target}.source == deployedSource
              && artifact.deployedAt == "${hostConfig.dotfiles.workstation.homeDir}/${target}"
            else
              artifact.deployedAt == null
          );

        sharedDeploymentMatches = lib.all (
          clientName:
          let
            client = clients.${clientName};
            homePrefix = hostConfig.dotfiles.workstation.homeDir;
            rulesArtifact = artifacts."agents/${clientName}/rules" or null;
            rulesMatch =
              if client.rulesDestination == null then
                rulesArtifact == null
              else
                rulesArtifact.source == normalizeSource hostConfig.dotfiles.agents.shared.rules
                && rulesArtifact.format == "markdown"
                && rulesArtifact.deployedAt == "${homePrefix}/${client.rulesDestination}"
                &&
                  homeConfig.home.file.${client.rulesDestination}.source
                  == normalizeSource hostConfig.dotfiles.agents.shared.rules;
            skillsMatch = lib.all (
              name:
              let
                artifact = artifacts."agents/${clientName}/skills/${name}";
              in
              artifact.source == normalizeSource hostConfig.dotfiles.agents.shared.skills.${name}
              && artifact.format == "directory"
              && artifact.deployedAt == "${homePrefix}/${client.skillsDestination}/${name}"
            ) (builtins.attrNames hostConfig.dotfiles.agents.shared.skills);
            subagentsMatch = lib.all (
              name:
              let
                suffix = if client.subagentFormat == "toml" then "toml" else "md";
                artifact = artifacts."agents/${clientName}/subagents/${name}";
                expectedFormat = if client.subagentFormat == "toml" then "toml" else "markdown";
              in
              if client.subagentsDestination == null then
                !(artifacts ? "agents/${clientName}/subagents/${name}")
              else
                homeConfig.home.file."${client.subagentsDestination}/${name}.${suffix}".source
                == normalizeSource client.subagents.${name}
                && artifact.source == normalizeSource client.subagents.${name}
                && artifact.format == expectedFormat
                && artifact.deployedAt == "${homePrefix}/${client.subagentsDestination}/${name}.${suffix}"
            ) (builtins.attrNames client.subagents);
          in
          lib.all (
            name:
            homeConfig.home.file."${client.skillsDestination}/${name}".source
            == normalizeSource hostConfig.dotfiles.agents.shared.skills.${name}
          ) (builtins.attrNames hostConfig.dotfiles.agents.shared.skills)
          && rulesMatch
          && skillsMatch
          && subagentsMatch
        ) (builtins.attrNames clients);

        expectedArtifactIds = lib.sort builtins.lessThan (
          lib.concatMap (
            clientName:
            let
              client = clients.${clientName};
            in
            lib.optional (client.rulesDestination != null) "agents/${clientName}/rules"
            ++ map (name: "agents/${clientName}/skills/${name}") (
              builtins.attrNames hostConfig.dotfiles.agents.shared.skills
            )
            ++ lib.optionals (client.subagentsDestination != null) (
              map (name: "agents/${clientName}/subagents/${name}") (builtins.attrNames client.subagents)
            )
            ++ map (id: "agents/${clientName}/${id}") (
              builtins.attrNames expected.clients.${clientName}.managedFiles
            )
          ) expected.required
        );
        actualAgentArtifactIds = lib.sort builtins.lessThan (
          builtins.filter (lib.hasPrefix "agents/") (builtins.attrNames artifacts)
        );

        seedActivation = homeConfig.home.activation.seedAgentConfigs.data;
        fixtureSeedActivation =
          builtins.replaceStrings [ hostConfig.dotfiles.workstation.homeDir ] [ "$fixture/home" ]
            seedActivation;
        fixtureSeedActivationScript = pkgs.writeShellScript "fixture-seed-agent-configs" fixtureSeedActivation;
        fixtureGenericSeedMigration = pkgs.writeShellScriptBin "fixture-generic-seed-migration" ''
          printf '%s\0' "$@" > "$MIGRATION_CAPTURE"
        '';
        codexSeedMigrationExe = lib.getExe clients.codex.managedFiles.user.seedMigrationCommand;
        fixtureGenericSeedActivation =
          builtins.replaceStrings
            [ codexSeedMigrationExe ]
            [
              (lib.getExe fixtureGenericSeedMigration)
            ]
            fixtureSeedActivation;
        managedRowsWithSeedMigration = builtins.filter (
          row: row.file.seedMigrationCommand != null
        ) managedRows;

        sharedSubagentSources = builtins.attrValues hostConfig.dotfiles.agents.shared.subagents;
        sharedSubagentNames = builtins.attrNames hostConfig.dotfiles.agents.shared.subagents;
        sharedSkillNames = builtins.attrNames hostConfig.dotfiles.agents.shared.skills;
        registrySkillSourcesMatch = lib.all (
          name:
          builtins.hasAttr name hostConfig.dotfiles.skills.registry
          &&
            toString hostConfig.dotfiles.agents.shared.skills.${name}
            == toString hostConfig.dotfiles.skills.registry.${name}.source
        ) sharedSkillNames;
        rawRoutingContract = import ../subagents/routing.nix;
        routingContract = hostConfig.dotfiles.agents.shared.routing;
        routedSkillNames = lib.unique (map (route: route.skill) routingContract.subagentSkills);
        routedSubagentNames = lib.unique (map (route: route.subagent) routingContract.subagentSkills);
        subagentSkillRouteKeys = map (
          route: "${route.subagent}/${route.skill}"
        ) routingContract.subagentSkills;
        subagentHandoffKeys = map (
          route: "${route.from}/${route.to}/${route.artifact}"
        ) routingContract.subagentHandoffs;
        requiredSkillsBySubagent = lib.genAttrs sharedSubagentNames (
          name:
          map (route: route.skill) (
            builtins.filter (
              route: route.subagent == name && route.activation == "required"
            ) routingContract.subagentSkills
          )
        );
        securitySubagentSource = hostConfig.dotfiles.agents.shared.subagents.security;
        claudeSubagentSources = builtins.attrValues clients.claude.subagents;
        codexSubagentSources = builtins.attrValues clients.codex.subagents;
        ompSubagentSources = builtins.attrValues clients.omp.subagents;
        opencodeSubagentSources = builtins.attrValues clients.opencode.subagents;
        sharedSubagentFarm = pkgs.linkFarm "shared-subagents" (
          lib.mapAttrsToList (name: path: {
            inherit name path;
          }) hostConfig.dotfiles.agents.shared.subagents
        );
        # 生成側とは独立に期待値を持つ。OMP は実装が同一の server だけ上流名を使い、OpenCode は
        # built-in id との衝突を避けるため所有者を前置する
        ompLspNames = {
          bash = "bashls";
          csharp = "roslyn-ls";
          java = "jdtls";
          nix = "nixd";
          python = "ty";
          rust = "rust-analyzer";
          typescript = "tsgo";
        };
        opencodeLspName = name: "dotfiles-${name}";
        selectionCases = {
          omp-only = {
            enabled = [ "omp" ];
            automaticUpdates = [ ];
          };
          replacement = {
            enabled = [ "codex" ];
            automaticUpdates = [ ];
          };
          trial = {
            enabled = [
              "claude"
              "omp"
            ];
            automaticUpdates = [ "claude" ];
          };
          upstream-only = {
            enabled = [ "antigravity" ];
            automaticUpdates = [ ];
          };
        };
        selectionConfigs = lib.mapAttrs (
          _: selection:
          (mkProbeSystem [
            normalMachineModule
            {
              dotfiles.agents.enabled = lib.mkForce selection.enabled;
              dotfiles.agents.automaticUpdates.clients = lib.mkForce selection.automaticUpdates;
            }
          ]).config
        ) selectionCases;
        selectionContractMatches =
          name: configuration:
          let
            selection = selectionCases.${name};
            selected = configuration.dotfiles.agents.clients;
            unselected = builtins.filter (id: !(builtins.elem id selection.enabled)) expected.required;
            home = configuration.home-manager.users.${configuration.dotfiles.workstation.username};
            artifactIds = builtins.filter (lib.hasPrefix "agents/") (
              builtins.attrNames configuration.dotfiles.managedArtifacts
            );
            clientObservationIds = builtins.filter (lib.hasPrefix "agents/client/") (
              builtins.attrNames configuration.dotfiles.health.observations
            );
            noClientDeployment =
              id:
              let
                client = configuration.dotfiles.agents.registry.${id};
              in
              !(builtins.hasAttr "${wrapperDirectory}/${client.binary}" home.home.file)
              && (client.rulesDestination == null || !(builtins.hasAttr client.rulesDestination home.home.file))
              && !lib.any (lib.hasPrefix "${client.skillsDestination}/") (builtins.attrNames home.home.file)
              && (
                client.subagentsDestination == null
                || !lib.any (lib.hasPrefix "${client.subagentsDestination}/") (builtins.attrNames home.home.file)
              )
              && !(builtins.hasAttr "agents/${id}/rules" configuration.dotfiles.managedArtifacts)
              && !lib.any (lib.hasPrefix "agents/${id}/") artifactIds
              && builtins.all (
                file:
                if file.deployment == "system" then
                  !(builtins.hasAttr file.destination configuration.environment.etc)
                else if file.deployment == "home" then
                  !(builtins.hasAttr file.destination home.home.file)
                else
                  !lib.hasInfix "${configuration.dotfiles.workstation.homeDir}/${file.destination}" home.home.activation.seedAgentConfigs.data
              ) (builtins.attrValues client.managedFiles);
            updatesEnabled = selection.automaticUpdates != [ ];
          in
          lib.all (entry: entry.assertion) configuration.assertions
          && (
            builtins.attrNames configuration.dotfiles.agents.registry == expected.required
            && builtins.attrNames selected == selection.enabled
            && builtins.attrNames configuration.dotfiles.agents.clientExecutables == selection.enabled
            && configuration.dotfiles.health.observations."agents/roster".members == selection.enabled
            && clientObservationIds == map (id: "agents/client/${id}") selection.enabled
            && builtins.all noClientDeployment unselected
            &&
              configuration.dotfiles.agents.runtime.skillRoots
              == map (id: expected.clients.${id}.skillsDestination) selection.enabled
            && (configuration.dotfiles.agents.runtime.timers.autoupdate != null) == updatesEnabled
            && (configuration.systemd.services ? dotfiles-agent-autoupdate) == updatesEnabled
            && (configuration.systemd.timers ? dotfiles-agent-autoupdate) == updatesEnabled
            && (configuration.dotfiles.health.observations ? "agents/maintenance/autoupdate") == updatesEnabled
            && !(configuration.dotfiles.agents.packages ? apm)
          );
        wrapperDirectory = ".local/share/dotfiles-agent/bin";
      in
      {
        agent-client-selection =
          assert lib.all (name: selectionContractMatches name selectionConfigs.${name}) (
            builtins.attrNames selectionCases
          );
          pkgs.runCommandLocal "check-agent-client-selection"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.jq
              ];
            }
            ''
              set -euo pipefail
              jq -e '.autoupdate == false' ${clients.opencode.managedFiles.config.source}
              ${lib.concatMapStrings (
                name:
                let
                  configuration = selectionConfigs.${name};
                  selection = selectionCases.${name};
                  installer = lib.getExe configuration.dotfiles.platform.cli.commands.installAgents;
                  updater = configuration.systemd.services.dotfiles-agent-autoupdate.serviceConfig.ExecStart or null;
                  policyFile = configuration.dotfiles.agents.shared.rules;
                  gate = lib.getExe configuration.dotfiles.agents.packages.verificationGate;
                in
                ''
                  ${installer} --print-manifest > ${name}-manifest.json
                  jq -e --argjson names ${lib.escapeShellArg (builtins.toJSON selection.enabled)} \
                    'map(.name) == $names' ${name}-manifest.json
                  ${lib.optionalString (updater != null) ''
                    ${updater} --print-manifest > ${name}-updates.json
                    jq -e --argjson names ${lib.escapeShellArg (builtins.toJSON selection.automaticUpdates)} \
                      'map(.name) == $names' ${name}-updates.json
                  ''}
                  ${lib.concatMapStrings (
                    id:
                    let
                      row = lib.escapeShellArg "| `${id}` |";
                    in
                    if builtins.elem id selection.enabled then
                      ''
                        grep -Fq ${row} ${policyFile}
                      ''
                    else
                      ''
                        if grep -Fq ${row} ${policyFile}; then
                          echo "unselected client policy remains: ${name}/${id}" >&2
                          exit 1
                        fi
                      ''
                  ) expected.required}
                  export HOME="$PWD/${name}-home"
                  mkdir -p "$HOME"
                  ${lib.concatMapStrings (id: ''
                    mkdir -p "$HOME/${expected.clients.${id}.skillsDestination}/codebase-design"
                  '') (builtins.filter (id: !(builtins.elem id selection.enabled)) expected.required)}
                  ${gate} teach --session ${name} --path /r/core/library.ts >/dev/null
                  mkdir -p "$HOME/${
                    expected.clients.${builtins.head selection.enabled}.skillsDestination
                  }/codebase-design"
                  cp ${configuration.dotfiles.agents.shared.skills.codebase-design}/SKILL.md \
                    "$HOME/${
                      expected.clients.${builtins.head selection.enabled}.skillsDestination
                    }/codebase-design/SKILL.md"
                  if ${gate} teach --session ${name} --path /r/core/library.ts >/dev/null 2>&1; then
                    echo "selected Skill root did not enforce its discipline: ${name}" >&2
                    exit 1
                  fi
                  ${gate} learned --session ${name} --path codebase-design
                  ${gate} teach --session ${name} --path /r/core/library.ts >/dev/null
                ''
              ) (builtins.attrNames selectionCases)}
              touch "$out"
            '';

        agent-claude-managed-policy =
          assert clients.claude.rulesDestination == null;
          assert !(homeConfig.home.file ? ".claude/CLAUDE.md");
          assert !(hostConfig.environment.etc ? "claude-code/CLAUDE.md");
          assert !(artifacts ? "agents/claude/rules");
          assert !(telemetryDisabledConfig.systemd.services ? otel-collector);
          assert !(telemetryDisabledConfig.dotfiles.managedArtifacts ? "telemetry/collector");
          assert
            lib.filterAttrs (
              name: _: lib.hasPrefix "telemetry/" name
            ) telemetryDisabledConfig.dotfiles.health.observations == { };
          pkgs.runCommandLocal "check-agent-claude-managed-policy"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.jq
              ];
            }
            ''
              set -euo pipefail
              jq -e --rawfile policy ${agentConfig.shared.rules} \
                '.claudeMd == $policy and (.claudeMd | length > 0) and .env.DISABLE_AUTOUPDATER == "1"' \
                ${artifactSource "agents/claude/managed-settings"}
              jq -e --rawfile policy ${selectionConfigs.trial.dotfiles.agents.shared.rules} \
                '.claudeMd == $policy and (.claudeMd | contains("| `claude` |"))' \
                ${selectionConfigs.trial.dotfiles.managedArtifacts."agents/claude/managed-settings".source}
              jq -e --rawfile policy ${restrictedAgentRules} '.claudeMd == $policy' \
                ${projectMemoryDisabledConfig.dotfiles.managedArtifacts."agents/claude/managed-settings".source}
              jq -e '.env.CLAUDE_CODE_ENABLE_TELEMETRY == "0"
                and .env.OTEL_METRICS_EXPORTER == "none" and .env.OTEL_LOGS_EXPORTER == "none"' \
                ${telemetryDisabledConfig.dotfiles.managedArtifacts."agents/claude/managed-settings".source}
              touch "$out"
            '';

        agent-config-migration =
          assert map (row: "${row.clientName}/${row.id}") managedRowsWithSeedMigration == [ "codex/user" ];
          assert fixtureGenericSeedActivation != fixtureSeedActivation;
          pkgs.runCommandLocal "check-agent-config-migration"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.ripgrep
              ];
            }
            ''
              set -euo pipefail

              if rg -n 'clientName[[:space:]]*==[[:space:]]*"codex"|clients\.codex|migrateCodexConfig' \
                ${self}/agents/module.nix; then
                echo "root agent module contains a Codex-specific branch" >&2
                exit 1
              fi

              fixture=$PWD/generic-seed-migration
              mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
              printf '%s\n' 'sandbox_mode = "workspace-write"' \
                > "$fixture/home/.codex/config.toml"
              export MIGRATION_CAPTURE=$fixture/migration-argv
              ${fixtureGenericSeedActivation}

              mapfile -d $'\0' -t migrationArgs < "$MIGRATION_CAPTURE"
              test "''${#migrationArgs[@]}" -eq 2
              test "''${migrationArgs[0]}" = "$fixture/home/.codex/config.toml"
              test "''${migrationArgs[1]}" = "$fixture/home"

              touch $out
            '';

        agent-artifact-contract =
          assert variantConfig.dotfiles.platform.mcp.gateway.port != gatewayPort;
          assert lib.count (package: package == installAgents) hostConfig.environment.systemPackages == 1;
          assert builtins.all managedDeploymentMatches managedRows;
          assert sharedDeploymentMatches;
          assert expectedArtifactIds == actualAgentArtifactIds;
          assert clients.claude.gatewayConfig.source == clients.claude.managedFiles.managed-mcp.source;
          assert clients.antigravity.gatewayConfig.source == clients.antigravity.managedFiles.mcp.source;
          assert clients.codex.gatewayConfig.source != clients.codex.managedFiles.system.source;
          assert clients.omp.gatewayConfig.source == clients.omp.managedFiles.mcp.source;
          assert clients.opencode.gatewayConfig.source != clients.opencode.managedFiles.config.source;
          assert lib.any (
            definition:
            lib.hasInfix "/agents/module.nix" (toString definition.file)
            && lib.elem hostConfig.dotfiles.capabilities.project-memory.clientIntegrations.hooks definition.value
          ) hostOptions.environment.systemPackages.definitionsWithLocations;
          assert
            clients.opencode.managedFiles.project-memory-plugin.source
            == hostConfig.dotfiles.capabilities.project-memory.clientIntegrations.opencodePlugin;
          assert !(builtins.hasAttr "containers/project-memory/opencode-capture" artifacts);
          assert lib.all (
            definition:
            lib.hasInfix "/agents/" (toString definition.file)
            && !lib.hasInfix "/containers/" (toString definition.file)
          ) hostOptions.dotfiles.agents.registry.definitionsWithLocations;
          # omp は hook directory の中の symlink を読まない。directory ごと配備し、中身は実 file にする
          assert lib.assertMsg (
            !lib.any (target: lib.hasPrefix ".omp/agent/hooks/pre/" target) (
              builtins.attrNames homeConfig.home.file
            )
          ) "omp hooks must not be deployed as individual file symlinks";
          pkgs.runCommandLocal "check-agent-artifact-contract"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.jq
                pkgs.remarshal
                pkgs.ripgrep
                pkgs.taplo
              ];
              codexSubagentSources = lib.concatStringsSep " " (map toString codexSubagentSources);
            }
            ''
              set -euo pipefail

              ${installAgentsExe} --print-manifest > install-manifest.json
              jq --sort-keys . install-manifest.json > actual-install-manifest.json
              printf '%s' ${lib.escapeShellArg (builtins.toJSON expectedInstallManifest)} \
                | jq --sort-keys . > expected-install-manifest.json
              diff --unified expected-install-manifest.json actual-install-manifest.json
              if grep -Fq 'read -r -a args' ${installAgentsExe} || grep -Fq "IFS='|'" ${installAgentsExe}; then
                echo "installer loses argument boundaries" >&2
                exit 1
              fi
              grep -Fq 'decode_version_args() {' ${installAgentsExe}
              grep -Fq 'run_version_check() {' ${installAgentsExe}
              if rg -n 'source .*version-args\.sh|/(nix/store|home)/[^ ]*version-args\.sh' ${installAgentsExe}; then
                echo "generated installer references an external versionArgs decoder" >&2
                exit 1
              fi

              runtimeHome=$PWD/generated-installer-runtime-home
              mkdir -p "$runtimeHome"
              : > "$runtimeHome/.local"
              if env -i HOME="$runtimeHome" ${installAgentsExe} \
                > generated-installer-runtime.stdout 2> generated-installer-runtime.stderr; then
                echo "generated installer unexpectedly accepted an invalid managed directory" >&2
                exit 1
              fi
              grep -Fq 'managed directory must be a real directory' generated-installer-runtime.stderr
              if grep -Fq 'not found in PATH' generated-installer-runtime.stderr; then
                echo "generated installer runtime closure is incomplete" >&2
                exit 1
              fi
              grep -Fq '${atomicPublishExe}' ${installAgentsExe}
              grep -Fq '${pkgs.diffutils}/bin' ${installAgentsExe}
              if rg -a -n 'FIXTURE_ATOMIC_HOOK_|@probeEnvironment@' ${installAgentsExe}; then
                echo "production installer contains the fixture probe hook interface" >&2
                exit 1
              fi
              test -x ${atomicPublishExe}
              if grep -aFq '${lib.getExe atomicPublishTestHook}' ${atomicPublishExe}; then
                echo "production atomic helper contains the fixture hook" >&2
                exit 1
              fi

              cat > fake-version <<'SCRIPT'
              #!${pkgs.runtimeShell}
              printf '%s\0' "$@" > "$ARG_CAPTURE"
              SCRIPT
              chmod +x fake-version
              export ARG_CAPTURE=$PWD/version-args
              source ${../impl/version-args.sh}
              # contract は空 argv を拒否する。decoder 単体では lossless transport の上位集合として空文字も保持する。
              run_version_check "$PWD/fake-version" ${
                lib.escapeShellArg (builtins.toJSON (losslessVersionArgs ++ [ "" ]))
              }
              mapfile -d $'\0' -t captured < "$ARG_CAPTURE"
              test "''${#captured[@]}" -eq 6
              test "''${captured[0]}" = $'trailing\n'
              test "''${captured[1]}" = $'\n'
              test "''${captured[2]}" = $'embedded\nline'
              test "''${captured[3]}" = '  spaced  '
              test "''${captured[4]}" = 'pipe|value'
              test -z "''${captured[5]}"

              fixtureHome=$PWD/installer-home
              mkdir -p "$fixtureHome/.local/bin"
              cat > "$fixtureHome/.local/bin/curl" <<'SCRIPT'
              #!${pkgs.runtimeShell}
              exit 0
              SCRIPT
              cat > "$fixtureHome/.local/bin/argv-capture" <<'SCRIPT'
              #!${pkgs.runtimeShell}
              printf '%s\0' "$@" > "$ARG_CAPTURE"
              SCRIPT
              chmod +x "$fixtureHome/.local/bin/curl" "$fixtureHome/.local/bin/argv-capture"
              export HOME=$fixtureHome
              export ARG_CAPTURE=$PWD/generated-installer-version-args
              ${losslessInstallAgentsExe}
              mapfile -d $'\0' -t generatedCaptured < "$ARG_CAPTURE"
              test "''${#generatedCaptured[@]}" -eq 5
              test "''${generatedCaptured[0]}" = $'trailing\n'
              test "''${generatedCaptured[1]}" = $'\n'
              test "''${generatedCaptured[2]}" = $'embedded\nline'
              test "''${generatedCaptured[3]}" = '  spaced  '
              test "''${generatedCaptured[4]}" = 'pipe|value'

              claudeCapabilities=${
                clients.claude.managedFiles.${clients.claude.capabilityManagedFiles.projectMemory}.source
              }
              test "$claudeCapabilities" = ${
                clients.claude.managedFiles.${clients.claude.capabilityManagedFiles.telemetry}.source
              }
              jq --exit-status \
                --arg endpoint ${lib.escapeShellArg hostConfig.dotfiles.telemetry.endpoint} \
                --arg protocol ${lib.escapeShellArg hostConfig.dotfiles.telemetry.protocol} \
                --argjson hooks ${lib.escapeShellArg (builtins.toJSON expectedClaudeHooks)} '
                .env.CLAUDE_CODE_ENABLE_TELEMETRY == "1" and
                .env.OTEL_METRICS_EXPORTER == "otlp" and
                .env.OTEL_LOGS_EXPORTER == "otlp" and
                .env.OTEL_EXPORTER_OTLP_ENDPOINT == $endpoint and
                .env.OTEL_EXPORTER_OTLP_PROTOCOL == $protocol and
                .hooks == $hooks
              ' "$claudeCapabilities" > /dev/null

              codexCapabilities=${
                clients.codex.managedFiles.${clients.codex.capabilityManagedFiles.projectMemory}.source
              }
              remarshal -if toml -of json "$codexCapabilities" \
                | jq --exit-status \
                  --argjson hooks ${lib.escapeShellArg (builtins.toJSON expectedCodexHooks)} '
                  .hooks == $hooks
                ' > /dev/null


              ompHookDirectory=${homeConfig.home.file.".omp/agent/hooks/pre".source}
              for hook in verification-gate.ts project-memory.ts; do
                if [ ! -f "$ompHookDirectory/$hook" ] || [ -L "$ompHookDirectory/$hook" ]; then
                  echo "omp hook is not a regular file in the deployed directory: $hook" >&2
                  exit 1
                fi
              done

              jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
                '. == {mcpServers: {gateway: {type: "http", url: $expected}}}' \
                ${clients.claude.gatewayConfig.source} > /dev/null
              jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
                '. == {mcpServers: {gateway: {serverUrl: $expected}}}' \
                ${clients.antigravity.gatewayConfig.source} > /dev/null
              jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
                '. == {mcp: {gateway: {type: "remote", url: $expected}}}' \
                ${clients.opencode.gatewayConfig.source} > /dev/null
              jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
                '. == {mcpServers: {gateway: {type: "http", url: $expected}}}' \
                ${clients.omp.gatewayConfig.source} > /dev/null
              remarshal -if toml -of json ${clients.codex.gatewayConfig.source} \
                | jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
                  '. == {mcp_servers: {gateway: {url: $expected}}}' > /dev/null

              jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
                '.mcp == {gateway: {type: "remote", url: $expected}}' \
                ${artifactSource "agents/opencode/config"} > /dev/null
              codex_mcp_matches() {
                local expected=$1
                jq --exit-status --arg expected "$expected" \
                  '.mcp_servers == {gateway: {url: $expected}}'
              }
              if grep -qE '@[a-zA-Z][a-zA-Z0-9]*@' ${artifactSource "agents/codex/system"}; then
                echo "generated Codex system config retains an unsubstituted marker" >&2
                exit 1
              fi
              remarshal -if toml -of json ${artifactSource "agents/codex/system"} > codex-system.json
              codex_mcp_matches ${lib.escapeShellArg gatewayUrl} < codex-system.json > /dev/null
              jq --exit-status \
                --arg cacheRoot ${lib.escapeShellArg "${hostConfig.dotfiles.workstation.homeDir}/.cache/dotfiles-wsl"} \
                --arg stateRoot ${lib.escapeShellArg "${hostConfig.dotfiles.workstation.homeDir}/.local/state/dotfiles-wsl"} \
                --arg systemSkillCreator ${lib.escapeShellArg "${hostConfig.dotfiles.workstation.homeDir}/.codex/skills/.system/skill-creator"} '
                .permissions == {dev: {filesystem: {($cacheRoot): "write", ($stateRoot): "write"}}} and
                .skills.config == [{path: $systemSkillCreator, enabled: false}] and
                (has("sandbox_mode") | not) and
                (has("sandbox_workspace_write") | not)
              ' codex-system.json > /dev/null
              remarshal -if toml -of json \
                ${clients.codex.managedFiles.user.source} > codex-user-seed.json
              grep -Fq '"@homeDir@/workspace"' ${self}/agents/clients/codex/assets/config.toml
              grep -Fq '"@homeDir@/projects"' ${self}/agents/clients/codex/assets/config.toml
              if rg -n '/home/nixos/(workspace|projects)' ${self}/agents/clients/codex/assets/config.toml; then
                echo "Codex seed hard-codes the host home directory" >&2
                exit 1
              fi
              jq --exit-status \
                --arg homeDir ${lib.escapeShellArg hostConfig.dotfiles.workstation.homeDir} '
                .default_permissions == "dev" and
                .permissions.dev.description == "workspace general profile" and
                .permissions.dev.extends == ":workspace" and
                .permissions.dev.filesystem == {
                  ":workspace_roots": {".": "write", ".git": "write"},
                  ($homeDir + "/workspace"): "write",
                  ($homeDir + "/projects"): "write"
                } and
                .permissions.dev.network == {enabled: true} and
                (has("sandbox_mode") | not) and
                (has("sandbox_workspace_write") | not)
              ' codex-user-seed.json > /dev/null
              for subagent in $codexSubagentSources; do
                remarshal -if toml -of json "$subagent" > codex-subagent.json
                jq --exit-status '
                  (has("sandbox_mode") | not) and
                  (has("sandbox_workspace_write") | not) and
                  (has("default_permissions") | not) and
                  (has("permissions") | not)
                ' codex-subagent.json > /dev/null
              done
              jq '.mcp_servers.extra = {url: "https://unexpected.invalid/mcp"}' \
                codex-system.json > codex-system-extra-server.json
              if codex_mcp_matches ${lib.escapeShellArg gatewayUrl} \
                < codex-system-extra-server.json > /dev/null; then
                echo "Codex system config accepted an undeclared MCP server" >&2
                exit 1
              fi

              jq --exit-status --arg expected ${lib.escapeShellArg variantGatewayUrl} \
                '.mcpServers.gateway.url == $expected and (.mcpServers | keys) == ["gateway"]' \
                ${variantClients.claude.managedFiles.managed-mcp.source} > /dev/null
              jq --exit-status --arg expected ${lib.escapeShellArg variantGatewayUrl} \
                '.mcpServers.gateway.serverUrl == $expected and (.mcpServers | keys) == ["gateway"]' \
                ${variantClients.antigravity.managedFiles.mcp.source} > /dev/null
              jq --exit-status --arg expected ${lib.escapeShellArg variantGatewayUrl} \
                '.mcp.gateway.url == $expected and (.mcp | keys) == ["gateway"]' \
                ${variantClients.opencode.managedFiles.config.source} > /dev/null
              jq --exit-status --arg expected ${lib.escapeShellArg variantGatewayUrl} \
                '.mcpServers.gateway == {type: "http", url: $expected} and (.mcpServers | keys) == ["gateway"]' \
                ${variantClients.omp.managedFiles.mcp.source} > /dev/null
              remarshal -if toml -of json ${variantClients.codex.managedFiles.system.source} \
                > codex-system-variant.json
              codex_mcp_matches ${lib.escapeShellArg variantGatewayUrl} \
                < codex-system-variant.json > /dev/null

              fixture=$PWD/seed-symlink-fixture
              mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
              printf '%s\n' keep-regular > "$fixture/home/.claude/settings.json"
              ln -s nowhere "$fixture/home/.codex/config.toml"
              if (${fixtureSeedActivation}); then
                echo "Codex seed activation accepted a symlink" >&2
                exit 1
              fi
              grep -Fxq keep-regular "$fixture/home/.claude/settings.json"
              test -L "$fixture/home/.codex/config.toml"

              fixture=$PWD/seed-symlink-parent-fixture
              mkdir -p "$fixture/home/.claude" "$fixture/home/actual-codex"
              printf '%s\n' keep-regular > "$fixture/home/.claude/settings.json"
              cat > "$fixture/home/actual-codex/config.toml" <<'TOML'
              sandbox_mode = "workspace-write"
              TOML
              ln -s actual-codex "$fixture/home/.codex"
              if (${fixtureSeedActivation}); then
                echo "Codex seed activation accepted a symlink parent" >&2
                exit 1
              fi
              grep -Fq 'sandbox_mode = "workspace-write"' \
                "$fixture/home/actual-codex/config.toml"

              cat > fake-stat <<'SCRIPT'
              #!${pkgs.runtimeShell}
              set -euo pipefail
              result=$(${pkgs.coreutils}/bin/stat "$@")
              path=''${!#}
              if [ "''${FIXTURE_STAT_WRONG_OWNER_PATH:-}" = "$path" ] \
                && [ "$1" = -c ] && [ "$2" = '%u:%d:%i' ]; then
                owner=''${result%%:*}
                printf '%s:%s\n' "$((owner + 1))" "''${result#*:}"
              else
                printf '%s\n' "$result"
              fi
              SCRIPT
              chmod +x fake-stat
              export FIXTURE_STAT=$PWD/fake-stat

              mapfile -t migration_exes < <(
                rg --only-matching \
                  '/nix/store/[a-z0-9]+-dotfiles-migrate-codex-config/bin/dotfiles-migrate-codex-config' \
                  ${fixtureSeedActivationScript} | sort -u
              )
              test "''${#migration_exes[@]}" -eq 1
              sed "s|''${migration_exes[0]}|${fixtureMigrateCodexConfig}|g" \
                ${fixtureSeedActivationScript} > fixture-owner-seed-activation
              chmod +x fixture-owner-seed-activation

              fixture=$PWD/seed-parent-owner-fixture
              export fixture
              mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
              printf '%s\n' 'sandbox_mode = "workspace-write"' \
                > "$fixture/home/.codex/config.toml"
              before=$(sha256sum "$fixture/home/.codex/config.toml")
              export FIXTURE_STAT_WRONG_OWNER_PATH=$fixture/home/.codex
              if ./fixture-owner-seed-activation; then
                echo "Codex seed activation accepted another owner for the target directory" >&2
                exit 1
              fi
              test "$(sha256sum "$fixture/home/.codex/config.toml")" = "$before"

              fixture=$PWD/seed-target-owner-fixture
              export fixture
              mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
              printf '%s\n' 'sandbox_mode = "workspace-write"' \
                > "$fixture/home/.codex/config.toml"
              before=$(sha256sum "$fixture/home/.codex/config.toml")
              export FIXTURE_STAT_WRONG_OWNER_PATH=$fixture/home/.codex/config.toml
              if ./fixture-owner-seed-activation; then
                echo "Codex seed activation accepted another owner for the target" >&2
                exit 1
              fi
              test "$(sha256sum "$fixture/home/.codex/config.toml")" = "$before"
              unset FIXTURE_STAT_WRONG_OWNER_PATH

              cat > fake-mktemp <<'SCRIPT'
              #!${pkgs.runtimeShell}
              set -euo pipefail
              count=0
              if [ -f "$FIXTURE_MKTEMP_COUNT" ]; then
                count=$(<"$FIXTURE_MKTEMP_COUNT")
              fi
              count=$((count + 1))
              printf '%s\n' "$count" > "$FIXTURE_MKTEMP_COUNT"
              if [ "''${FIXTURE_MKTEMP_FAIL_SECOND:-0}" = 1 ] && [ "$count" -eq 2 ]; then
                exit 1
              fi
              path=$(${pkgs.coreutils}/bin/mktemp "$@")
              if [ "$count" -eq 1 ]; then
                printf '%s\n' "$path" > "$FIXTURE_FIRST_TEMP"
              fi
              printf '%s\n' "$path"
              SCRIPT
              chmod +x fake-mktemp

              cat > fake-remarshal <<'SCRIPT'
              #!${pkgs.runtimeShell}
              set -euo pipefail
              count=0
              if [ -f "$FIXTURE_REMARSHAL_COUNT" ]; then
                count=$(<"$FIXTURE_REMARSHAL_COUNT")
              fi
              count=$((count + 1))
              printf '%s\n' "$count" > "$FIXTURE_REMARSHAL_COUNT"
              ${lib.getExe pkgs.remarshal} "$@"
              if [ "''${FIXTURE_REPLACE_TARGET_ON_THIRD:-0}" = 1 ] && [ "$count" -eq 3 ]; then
                ${pkgs.coreutils}/bin/mv -T \
                  "$FIXTURE_REPLACEMENT_SOURCE" "$FIXTURE_REPLACE_TARGET"
              fi
              SCRIPT
              chmod +x fake-remarshal

              fixture=$PWD/migration-cleanup-fixture
              mkdir -p "$fixture/home/.codex"
              printf '%s\n' 'sandbox_mode = "workspace-write"' \
                > "$fixture/home/.codex/config.toml"
              export FIXTURE_MKTEMP=$PWD/fake-mktemp
              export FIXTURE_REMARSHAL=$PWD/fake-remarshal
              export FIXTURE_MKTEMP_COUNT=$fixture/mktemp-count
              export FIXTURE_FIRST_TEMP=$fixture/first-temp
              export FIXTURE_REMARSHAL_COUNT=$fixture/remarshal-count
              export FIXTURE_MKTEMP_FAIL_SECOND=1
              if ${fixtureMigrateCodexConfig} \
                "$fixture/home/.codex/config.toml" "$fixture/home"; then
                echo "Codex migration accepted a failed second mktemp" >&2
                exit 1
              fi
              first_temp=$(<"$FIXTURE_FIRST_TEMP")
              test ! -e "$first_temp"

              fixture=$PWD/migration-race-fixture
              mkdir -p "$fixture/home/.codex"
              printf '%s\n' 'sandbox_mode = "workspace-write"' \
                > "$fixture/home/.codex/config.toml"
              printf '%s\n' 'replacement = true' > "$fixture/replacement.toml"
              : > "$fixture/mktemp-count"
              : > "$fixture/remarshal-count"
              printf '0\n' > "$fixture/mktemp-count"
              printf '0\n' > "$fixture/remarshal-count"
              export FIXTURE_MKTEMP_COUNT=$fixture/mktemp-count
              export FIXTURE_FIRST_TEMP=$fixture/first-temp
              export FIXTURE_REMARSHAL_COUNT=$fixture/remarshal-count
              export FIXTURE_MKTEMP_FAIL_SECOND=0
              export FIXTURE_REPLACE_TARGET_ON_THIRD=1
              export FIXTURE_REPLACE_TARGET=$fixture/home/.codex/config.toml
              export FIXTURE_REPLACEMENT_SOURCE=$fixture/replacement.toml
              if ${fixtureMigrateCodexConfig} \
                "$fixture/home/.codex/config.toml" "$fixture/home"; then
                echo "Codex migration published over a replaced target" >&2
                exit 1
              fi
              grep -Fxq 'replacement = true' "$fixture/home/.codex/config.toml"
              unset FIXTURE_REPLACE_TARGET_ON_THIRD FIXTURE_REPLACE_TARGET \
                FIXTURE_REPLACEMENT_SOURCE

              fixture=$PWD/seed-legacy-fixture
              mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
              printf '%s\n' keep-regular > "$fixture/home/.claude/settings.json"
              cat > "$fixture/home/.codex/config.toml" <<'TOML'
              model = "fixture-model"
              sandbox_mode = "workspace-write"
              custom_unknown = "preserved"

              [sandbox_workspace_write]
              network_access = true

              [custom_table]
              answer = 42
              TOML
              ${fixtureSeedActivation}
              remarshal -if toml -of json "$fixture/home/.codex/config.toml" > migrated.json
              jq --exit-status \
                --arg homeDir "$fixture/home" '
                .model == "fixture-model" and
                .custom_unknown == "preserved" and
                .custom_table == {answer: 42} and
                .default_permissions == "dev" and
                .permissions.dev.extends == ":workspace" and
                .permissions.dev.filesystem == {
                  ":workspace_roots": {".": "write", ".git": "write"},
                  ($homeDir + "/workspace"): "write",
                  ($homeDir + "/projects"): "write"
                } and
                .permissions.dev.network == {enabled: true} and
                (has("sandbox_mode") | not) and
                (has("sandbox_workspace_write") | not)
              ' migrated.json > /dev/null
              test "$(stat -c %a "$fixture/home/.codex/config.toml")" = 600

              fixture=$PWD/seed-current-fixture
              mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
              cp ${clients.codex.managedFiles.user.source} "$fixture/home/.codex/config.toml"
              before=$(sha256sum "$fixture/home/.codex/config.toml")
              ${fixtureSeedActivation}
              test "$(sha256sum "$fixture/home/.codex/config.toml")" = "$before"

              fixture=$PWD/seed-invalid-fixture
              mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
              printf 'not = [valid\n' > "$fixture/home/.codex/config.toml"
              if (${fixtureSeedActivation}); then
                echo "Codex seed activation accepted invalid TOML" >&2
                exit 1
              fi

              fixture=$PWD/seed-nonregular-fixture
              mkdir -p "$fixture/home/.claude" "$fixture/home/.codex/config.toml"
              if (${fixtureSeedActivation}); then
                echo "Codex seed activation accepted a non-regular file" >&2
                exit 1
              fi

              fixture=$PWD/seed-missing-fixture
              mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
              mkdir "$fixture/home/.claude/settings.json"
              ${fixtureSeedActivation}
              test -d "$fixture/home/.claude/settings.json"
              test -s "$fixture/home/.codex/config.toml"
              test -s "$fixture/home/.omp/agent/config.yml"
              remarshal -if yaml -of json "$fixture/home/.omp/agent/config.yml" > omp-seed.json
              jq --exit-status '.bashInterceptor.enabled == true' omp-seed.json \
                > /dev/null

              rmdir "$fixture/home/.claude/settings.json"
              ${fixtureSeedActivation}
              test -s "$fixture/home/.claude/settings.json"

              test ! -e ${self}/clis
              legacy_root=clis
              legacy_role=cli
              legacy_option=m
              legacy_option+='y\.'
              legacy_pattern="$legacy_option''${legacy_root}|dotfiles-install-''${legacy_root}|dotfiles-''${legacy_role}-autoupdate|''${legacy_root}/assets|''${legacy_root}/(antigravity|claude|codex|omp|opencode)"
              if rg -n "$legacy_pattern" ${self}; then
                echo "legacy clis path or runtime identity remains" >&2
                exit 1
              fi
              test ! -e ${self}/agents/shared
              test -f ${self}/agents/policy/AGENTS.md
              test -f ${self}/agents/subagents/routing.nix
              for client in antigravity claude codex omp opencode; do
                test -f "${self}/agents/clients/$client/module.nix"
              done
              touch $out
            '';

        agent-capability-gating =
          assert lib.all (entry: entry.assertion) projectMemoryDisabledConfig.assertions;
          assert !builtins.hasAttr "projectMemoryHooks" projectMemoryDisabledConfig.dotfiles.agents.packages;
          assert
            !builtins.hasAttr "agentMemoryHarvest" projectMemoryDisabledConfig.dotfiles.platform.cli.commands;
          assert !builtins.hasAttr "dotfiles-agent-memory-harvest" projectMemoryDisabledConfig.systemd.timers;
          assert lib.all (client: client.projectMemoryMode == "unsupported") (
            builtins.attrValues projectMemoryDisabledConfig.dotfiles.agents.clients
          );
          assert
            !builtins.hasAttr "agents/opencode/project-memory-plugin" projectMemoryDisabledConfig.dotfiles.managedArtifacts;
          assert builtins.hasAttr "agents/omp/hooks" projectMemoryDisabledConfig.dotfiles.managedArtifacts;
          assert builtins.hasAttr "diagnosing-bugs" minimalCapabilitySkills;
          assert lib.all (skill: !builtins.hasAttr skill minimalCapabilitySkills) [
            "a11y-debugging"
            "browser-performance"
            "debug-optimize-lcp"
          ];
          assert lib.all (
            route: builtins.hasAttr route.skill minimalCapabilitySkills
          ) minimalCapabilityConfig.dotfiles.agents.shared.routing.subagentSkills;
          pkgs.runCommandLocal "check-agent-capability-gating" { } ''
            if [ -e ${
              projectMemoryDisabledConfig.dotfiles.managedArtifacts."agents/omp/hooks".source
            }/project-memory.ts ]; then
              echo "disabled project-memory remained in OMP hooks" >&2
              exit 1
            fi
            touch $out
          '';

        agent-subagent-rendering =
          assert builtins.elem "browser-automation"
            transitiveCapabilityAgentConfig.dotfiles.capabilities.resolved;
          assert builtins.elem "browser-runtime"
            transitiveCapabilityAgentConfig.dotfiles.capabilities.resolved;
          assert
            !(builtins.elem "browser-diagnostics" transitiveCapabilityAgentConfig.dotfiles.capabilities.resolved);
          assert builtins.hasAttr "browser-operation"
            transitiveCapabilityAgentConfig.dotfiles.agents.shared.skills;
          assert
            !builtins.hasAttr "browser-performance" transitiveCapabilityAgentConfig.dotfiles.agents.shared.skills;
          assert clients.claude.subagents != hostConfig.dotfiles.agents.shared.subagents;
          assert builtins.attrNames clients.claude.subagents == sharedSubagentNames;
          assert clients.antigravity.subagents == { };
          assert builtins.elem "filter-syntax" hostConfig.dotfiles.skills.enabled;
          assert isReferenceOnlySkill hostConfig.dotfiles.skills.registry.filter-syntax.source;
          assert !builtins.hasAttr "filter-syntax" hostConfig.dotfiles.agents.shared.skills;
          assert !(isReferenceOnlySkill hostConfig.dotfiles.skills.registry.grill-me.source);
          assert builtins.hasAttr "grill-me" hostConfig.dotfiles.agents.shared.skills;
          assert lib.all (
            clientName:
            !(builtins.hasAttr "${clients.${clientName}.skillsDestination}/filter-syntax" homeConfig.home.file)
            && !(builtins.hasAttr "agents/${clientName}/skills/filter-syntax" artifacts)
          ) (builtins.attrNames clients);
          assert lib.all (name: builtins.elem name sharedSkillNames) routedSkillNames;
          assert lib.sort builtins.lessThan routedSubagentNames == sharedSubagentNames;
          assert requiredSkillsBySubagent.reviewer == [ ];
          assert lib.any (
            route: route.subagent == "reviewer" && route.skill == "code-review" && route.activation == "dynamic"
          ) routingContract.subagentSkills;
          assert
            !(lib.any (
              route:
              builtins.elem route.skill [
                "ponytail"
                "ponytail-review"
                "filter-syntax"
              ]
            ) routingContract.subagentSkills);
          assert
            builtins.length subagentSkillRouteKeys == builtins.length (lib.unique subagentSkillRouteKeys);
          assert builtins.length subagentHandoffKeys == builtins.length (lib.unique subagentHandoffKeys);
          assert lib.all (
            route: builtins.elem route.from sharedSubagentNames && builtins.elem route.to sharedSubagentNames
          ) routingContract.subagentHandoffs;
          assert clients.claude.skillProjectionMode == "preload";
          assert clients.omp.skillProjectionMode == "preload";
          assert clients.codex.skillProjectionMode == "dynamic";
          assert clients.opencode.skillProjectionMode == "dynamic";
          assert clients.antigravity.skillProjectionMode == "unsupported";
          assert sharedSubagentSources != [ ];
          assert claudeSubagentSources != [ ];
          assert codexSubagentSources != [ ];
          assert ompSubagentSources != [ ];
          assert opencodeSubagentSources != [ ];
          assert lib.all (source: lib.hasPrefix builtins.storeDir (toString source)) (
            builtins.attrValues hostConfig.dotfiles.agents.shared.skills
          );
          assert registrySkillSourcesMatch;
          pkgs.runCommandLocal "check-agent-subagent-rendering"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.diffutils
                pkgs.glibc.bin
                pkgs.gnugrep
                pkgs.jq
                pkgs.remarshal
                pkgs.yq
              ];
              rulesSource = hostConfig.dotfiles.agents.shared.rules;
              requiredSkillsJson = builtins.toJSON requiredSkillsBySubagent;
              routingJson = builtins.toJSON rawRoutingContract;
              inherit sharedSubagentFarm;
              claudeSubagentsJson = builtins.toJSON (lib.mapAttrs (_: toString) clients.claude.subagents);
              ompSubagentsJson = builtins.toJSON (lib.mapAttrs (_: toString) clients.omp.subagents);
              inherit securitySubagentSource;
              sharedSources = sharedSubagentSources;
              claudeSources = claudeSubagentSources;
              codexSources = codexSubagentSources;
              ompSources = ompSubagentSources;
              opencodeSources = opencodeSubagentSources;
              discoverableSkillNamesJson = builtins.toJSON sharedSkillNames;
              helperSource = hostConfig.dotfiles.skills.registry.filter-syntax.source;
              consumerSources = lib.concatMapStringsSep " " (
                clientName:
                toString homeConfig.home.file."${clients.${clientName}.skillsDestination}/run-tests".source
              ) (builtins.attrNames clients);
              skillEntries = lib.concatStringsSep " " (
                lib.mapAttrsToList (name: skill: "${name}=${skill.source}/SKILL.md") policySkills
              );
            }
            ''
              set -euo pipefail

              test -s "$rulesSource"
              mkdir projected-skills
              for consumerSource in $consumerSources; do
                ln -s "$consumerSource" projected-skills/run-tests
                test ! -e projected-skills/filter-syntax
                originalConsumer=$(realpath projected-skills/run-tests)
                test -r "$originalConsumer/../filter-syntax/SKILL.md"
                cmp "$helperSource/SKILL.md" "$originalConsumer/../filter-syntax/SKILL.md"
                rm projected-skills/run-tests
              done
              iconv -f UTF-8 -t UTF-8 "$rulesSource" > /dev/null
              grep -Eq '^#{1,6}[[:space:]]+[^[:space:]]' "$rulesSource"
              while IFS=$'\t' read -r subagent skill; do
                source="$sharedSubagentFarm/$subagent"
                if ! grep -Fq "\`$skill\`" "$source"; then
                  echo "subagent Skill route is absent from its definition: $subagent/$skill" >&2
                  exit 1
                fi
              done < <(jq -r '.subagentSkills[] | [.subagent, .skill] | @tsv' <<<"$routingJson")
              while IFS=$'\t' read -r from to artifact; do
                source="$sharedSubagentFarm/$from"
                if ! grep -Fq "\`$artifact\`" "$source" || ! grep -Fq "$to" "$source"; then
                  echo "subagent handoff route is absent from its definition: $from/$to/$artifact" >&2
                  exit 1
                fi
              done < <(jq -r '.subagentHandoffs[] | [.from, .to, .artifact] | @tsv' <<<"$routingJson")

              for entry in $skillEntries; do
                name=''${entry%%=*}
                source=''${entry#*=}
                closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$source")
                test -n "$closing"
                sed -n "2,$((closing - 1))p" "$source" > expected-frontmatter.yaml
                expectedDiscovery=$(yq -r '
                  (.["user-invocable"] == false and .["disable-model-invocation"] == true) | not
                ' expected-frontmatter.yaml)
                actualDiscovery=$(jq -r --arg name "$name" 'index($name) != null' <<<"$discoverableSkillNamesJson")
                if [ "$actualDiscovery" != "$expectedDiscovery" ]; then
                  echo "native Skill discovery disagrees with invocation flags: $name" >&2
                  exit 1
                fi
              done
              if grep -qE '@[a-zA-Z][a-zA-Z0-9]*@' "$rulesSource"; then
                echo 'generated policy retains an unsubstituted marker' >&2
                exit 1
              fi

              check_frontmatter() {
                local source=$1 closing
                test "$(head -n 1 "$source")" = '---'
                closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$source")
                test -n "$closing"
                sed -n "2,$((closing - 1))p" "$source" > frontmatter.yaml
                tail -n "+$((closing + 1))" "$source" > body.md
                yq '.' frontmatter.yaml > /dev/null
                grep -Eq '[^[:space:]]' body.md
              }

              for source in $sharedSources; do
                check_frontmatter "$source"
                if grep -Eq '@(skillRouting|handoffs)@' "$source"; then
                  echo "generated subagent retained a routing marker: $source" >&2
                  exit 1
                fi
                yq --exit-status '
                  (.tools | all(. == "Read" or . == "Grep" or . == "Glob" or
                    . == "Edit" or . == "Write" or . == "Bash" or
                    . == "WebSearch" or . == "WebFetch"))
                ' frontmatter.yaml > /dev/null
              done
              while IFS=$'\t' read -r name source; do
                check_frontmatter "$source"
                expected=$(jq -c --arg name "$name" '.[$name]' <<<"$requiredSkillsJson")
                actual=$(yq -c '.skills // []' frontmatter.yaml)
                test "$actual" = "$expected"
                yq --exit-status '
                  (.tools | index("Skill")) != null and
                  (.tools | index("mcp__gateway")) != null and
                  (.tools | all(. == "Read" or . == "Grep" or . == "Glob" or
                    . == "Edit" or . == "Write" or . == "Bash" or
                    . == "WebSearch" or . == "WebFetch" or
                    . == "Skill" or . == "mcp__gateway"))
                ' frontmatter.yaml > /dev/null
              done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$claudeSubagentsJson")
              for source in $opencodeSources; do
                check_frontmatter "$source"
                yq --exit-status '
                  .tools.skill == true and
                  (.tools | keys | all(. == "read" or . == "grep" or . == "glob" or
                    . == "edit" or . == "write" or . == "bash" or
                    . == "websearch" or . == "webfetch" or . == "skill"))
                ' frontmatter.yaml > /dev/null
              done
              while IFS=$'\t' read -r name source; do
                check_frontmatter "$source"
                expected=$(jq -c --arg name "$name" '.[$name]' <<<"$requiredSkillsJson")
                actual=$(yq -c '.autoloadSkills // []' frontmatter.yaml)
                test "$actual" = "$expected"
                yq --exit-status '
                  (.name | length) > 0 and
                  (.description | length) > 0 and
                  .["thinking-level"] == "xhigh" and
                  (has("effort") | not) and
                  (.tools | all(. == "read" or . == "grep" or . == "glob" or
                    . == "edit" or . == "write" or . == "bash" or
                    . == "web_search"))
                ' frontmatter.yaml > /dev/null
              done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$ompSubagentsJson")
              for source in $codexSources; do
                remarshal -if toml -of json "$source" > subagent.json
                jq --exit-status '.developer_instructions | length > 0' subagent.json > /dev/null
              done

              extract_subagent_section() {
                local heading=$1 source=$2
                awk -v heading="$heading" '
                  $0 == heading { inside = 1; next }
                  inside && /^## / { exit }
                  inside { print }
                ' "$source"
              }
              extract_subagent_section '## Scan' "$securitySubagentSource" > security-scan-section.md
              for phase in security-review threat-model finding-discovery validation attack-path-analysis; do
                grep -Fq "$phase" security-scan-section.md
              done
              grep -Fq 'security-review → threat-model → finding-discovery → validation → attack-path-analysis → 最終 report' \
                security-scan-section.md
              if grep -Fq 'fix-finding' security-scan-section.md; then
                echo "security scan phase includes finding repair" >&2
                exit 1
              fi
              extract_subagent_section '## Finding fix handoff' "$securitySubagentSource" \
                > security-fix-handoff-section.md
              grep -Fq 'fix-finding' security-fix-handoff-section.md
              grep -Fq 'validated-finding-attack-path' security-fix-handoff-section.md
              grep -Fq '修正を実装しない' security-fix-handoff-section.md
              grep -Fq '$HOME/.local/state/dotfiles-wsl/security-scans/<repo_name>' \
                "$securitySubagentSource"
              grep -Fq '再現用の使い捨てdataだけを割り当て済み`TMPDIR`へ置き' \
                "$securitySubagentSource"
              grep -Fq 'plugin既定の`/tmp/codex-security-scans/<repo_name>`は使わない' \
                "$securitySubagentSource"
              security_frontmatter_end=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' \
                "$securitySubagentSource")
              sed -n "2,$((security_frontmatter_end - 1))p" "$securitySubagentSource" \
                > security-frontmatter.yaml
              yq --exit-status '.tools == ["Read", "Bash", "Grep", "Glob"]' \
                security-frontmatter.yaml > /dev/null

              compare_subagent_bodies() {
                local shared=$1 rendered=$2 shared_end rendered_end
                shared_end=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$shared")
                rendered_end=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$rendered")
                diff --unified \
                  <(tail -n "+$((shared_end + 1))" "$shared") \
                  <(tail -n "+$((rendered_end + 1))" "$rendered")
              }
              paste \
                <(printf '%s\n' $sharedSources) \
                <(printf '%s\n' $claudeSources) \
                | while IFS=$'\t' read -r shared claude; do
                    compare_subagent_bodies "$shared" "$claude"
                  done
              paste \
                <(printf '%s\n' $sharedSources) \
                <(printf '%s\n' $ompSources) \
                | while IFS=$'\t' read -r shared omp; do
                    compare_subagent_bodies "$shared" "$omp"
                  done

              touch $out
            '';

        lsp-registration =
          pkgs.runCommandLocal "check-lsp-registration"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.coreutils
              ];
            }
            ''
              set -euo pipefail

              managedSettings=${artifactSource "agents/claude/managed-settings"}
              marketplace=$(jq -r '.extraKnownMarketplaces.dotfiles.source.path' "$managedSettings")
              claudeLsp="$marketplace/lsp/.lsp.json"

              jq --sort-keys 'keys' "$claudeLsp" > claude-names.json
              jq --sort-keys 'keys' ${artifactSource "agents/omp/lsp"} > omp-names.json
              jq --sort-keys '.lsp | keys' ${artifactSource "agents/opencode/config"} > opencode-names.json
              printf '%s' ${lib.escapeShellArg (builtins.toJSON (builtins.attrNames roster))} \
                | jq --sort-keys '.' > expected-names.json
              diff --unified expected-names.json claude-names.json
              printf '%s' ${lib.escapeShellArg (builtins.toJSON (lib.sort builtins.lessThan (map opencodeLspName (builtins.attrNames roster))))} \
                | jq --sort-keys '.' > expected-opencode-names.json
              diff --unified expected-opencode-names.json opencode-names.json
              printf '%s' ${lib.escapeShellArg (builtins.toJSON (lib.sort builtins.lessThan (builtins.attrValues ompLspNames)))} \
                | jq --sort-keys '.' > expected-omp-names.json
              diff --unified expected-omp-names.json omp-names.json

              ${lib.concatMapStrings (name: ''
                jq --exit-status \
                  --arg command ${lib.escapeShellArg roster.${name}.command} \
                  --argjson args ${lib.escapeShellArg (builtins.toJSON roster.${name}.args)} \
                  --argjson extensions ${lib.escapeShellArg (builtins.toJSON roster.${name}.extensions)} \
                  --argjson options ${lib.escapeShellArg (builtins.toJSON roster.${name}.initializationOptions)} '
                  .["${name}"].command == $command and
                  (.["${name}"].args // []) == $args and
                  .["${name}"].extensionToLanguage == $extensions and
                  (.["${name}"].initializationOptions // {}) == $options
                ' "$claudeLsp" > /dev/null

                jq --exit-status \
                  --argjson command ${
                    lib.escapeShellArg (builtins.toJSON ([ roster.${name}.command ] ++ roster.${name}.args))
                  } \
                  --argjson extensions ${
                    lib.escapeShellArg (builtins.toJSON (builtins.attrNames roster.${name}.extensions))
                  } \
                  --argjson options ${lib.escapeShellArg (builtins.toJSON roster.${name}.initializationOptions)} '
                  .lsp["${opencodeLspName name}"].command == $command and
                  (.lsp["${opencodeLspName name}"].extensions | sort) == ($extensions | sort) and
                  (.lsp["${opencodeLspName name}"].initialization // {}) == $options
                ' ${artifactSource "agents/opencode/config"} > /dev/null

                jq --exit-status \
                  --arg command ${lib.escapeShellArg roster.${name}.command} \
                  --argjson args ${lib.escapeShellArg (builtins.toJSON roster.${name}.args)} \
                  --argjson fileTypes ${
                    lib.escapeShellArg (builtins.toJSON (builtins.attrNames roster.${name}.extensions))
                  } \
                  --argjson options ${lib.escapeShellArg (builtins.toJSON roster.${name}.initializationOptions)} '
                  .["${ompLspNames.${name}}"].command == $command and
                  .["${ompLspNames.${name}}"].args == $args and
                  (.["${ompLspNames.${name}}"].fileTypes | sort) == ($fileTypes | sort) and
                  (.["${ompLspNames.${name}}"].initOptions // {}) == $options and
                  .["${ompLspNames.${name}}"].rootMarkers == ["."]
                ' ${artifactSource "agents/omp/lsp"} > /dev/null
              '') (builtins.attrNames roster)}

              jq -r '.[].extensionToLanguage | keys[]' "$claudeLsp" | sort > extensions
              test "$(sort -u extensions | wc -l)" = "$(wc -l < extensions)"

              jq --exit-status '
                .extraKnownMarketplaces.dotfiles.source.source == "directory" and
                .enabledPlugins["lsp@dotfiles"] == true
              ' "$managedSettings" > /dev/null
              jq --exit-status '
                .name == "dotfiles" and
                (.plugins | length) == 1 and
                .plugins[0].name == "lsp" and
                .plugins[0].source == "./lsp" and
                (.plugins[0].version | length) > 0
              ' "$marketplace/.claude-plugin/marketplace.json" > /dev/null
              touch $out
            '';

        agent-no-checkout-deployment =
          let
            inherit (hostConfig.dotfiles.workstation) homeDir;
            checkoutDir = hostConfig.dotfiles.workstation.dotfilesDir;
            insideCheckout = path: path == checkoutDir || lib.hasPrefix "${checkoutDir}/" path;
            deployedTargets =
              map (name: "${homeDir}/${name}") (builtins.attrNames homeConfig.home.file)
              ++ lib.concatMap (artifact: lib.optional (artifact.deployedAt != null) artifact.deployedAt) (
                builtins.attrValues artifacts
              );
          in
          assert !lib.any insideCheckout deployedTargets;
          assert !(artifacts ? "agents/codex/project");
          assert
            builtins.attrNames clients.codex.managedFiles == [
              "system"
              "user"
            ];
          assert !lib.hasInfix "${checkoutDir}/.codex" seedActivation;
          pkgs.runCommandLocal "check-agent-no-checkout-deployment"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.remarshal
              ];
            }
            ''
              set -euo pipefail
              remarshal -if toml -of json ${artifactSource "agents/codex/system"} > codex-system.json
              jq --exit-status \
                --arg cacheRoot ${lib.escapeShellArg "${homeDir}/.cache/dotfiles-wsl"} \
                --arg stateRoot ${lib.escapeShellArg "${homeDir}/.local/state/dotfiles-wsl"} \
                '.permissions.dev.filesystem == {($cacheRoot): "write", ($stateRoot): "write"}' \
                codex-system.json > /dev/null
              touch $out
            '';

        # 同 ID の供給元差替と戻しは Skill registry の既存入口だけで行い、二つの client へ原文のまま届く
        agent-skill-replacement =
          let
            skillFixtures = ../fixtures/skill-replacement;
            replacement = {
              source = skillFixtures + "/browser-operation";
              requiresCapabilities = [ ];
              requiresSkills = [ ];
            };
            external = {
              source = skillFixtures + "/external-procedure";
              requiresCapabilities = [ ];
              requiresSkills = [ ];
            };
            replacedConfig =
              (mkProbeSystem [
                normalMachineModule
                {
                  dotfiles.capabilities.enabled = lib.mkForce [ "project-memory" ];
                  dotfiles.skills.registry.browser-operation = lib.mkForce replacement;
                  dotfiles.skills.registry.external-procedure = external;
                }
              ]).config;
            conflictingConfig =
              (mkProbeSystem [
                normalMachineModule
                { dotfiles.skills.registry.browser-operation = replacement; }
              ]).config;
            conflictAccepted =
              (builtins.tryEval (builtins.deepSeq conflictingConfig.dotfiles.agents.shared.skills true)).success;
            replacedHome = replacedConfig.home-manager.users.${replacedConfig.dotfiles.workstation.username};
            projectedClients = [
              "omp"
              "claude"
            ];
            deployed =
              clientName: skill:
              replacedHome.home.file."${
                replacedConfig.dotfiles.agents.clients.${clientName}.skillsDestination
              }/${skill}".source;
            routesTo =
              configuration: skill:
              lib.any (route: route.skill == skill) configuration.dotfiles.agents.shared.routing.subagentSkills;
          in
          # 差替先の依存宣言へ切り替わり、旧 source の Capability 要求は残らない
          assert !(minimalCapabilityConfig.dotfiles.agents.shared.skills ? browser-operation);
          assert !routesTo minimalCapabilityConfig "browser-operation";
          assert replacedConfig.dotfiles.agents.shared.skills ? browser-operation;
          assert routesTo replacedConfig "browser-operation";
          assert replacedConfig.dotfiles.skills.registry.browser-operation.requiresCapabilities == [ ];
          # 同優先度の競合する差替は拒否する
          assert !conflictAccepted;
          # reference-only の helper は全 client の named Skill へ出さない
          assert !(replacedConfig.dotfiles.agents.shared.skills ? filter-syntax);
          assert lib.all (
            clientName:
            !(
              replacedHome.home.file
                ? "${replacedConfig.dotfiles.agents.clients.${clientName}.skillsDestination}/filter-syntax"
            )
          ) (builtins.attrNames replacedConfig.dotfiles.agents.clients);
          # 元へ戻す場合は差替定義を外すだけで、元の source へ戻る
          assert
            toString hostConfig.dotfiles.agents.shared.skills.browser-operation
            == toString hostConfig.dotfiles.skills.registry.browser-operation.source;
          assert
            toString hostConfig.dotfiles.agents.shared.skills.browser-operation != toString replacement.source;
          pkgs.runCommandLocal "check-agent-skill-replacement"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
              ];
              replacementSources = lib.concatMapStringsSep " " (
                clientName: "${deployed clientName "browser-operation"}"
              ) projectedClients;
              externalSources = lib.concatMapStringsSep " " (
                clientName: "${deployed clientName "external-procedure"}"
              ) projectedClients;
              replacementFixture = "${replacement.source}";
              externalFixture = "${external.source}";
            }
            ''
              set -euo pipefail
              for source in $replacementSources; do
                cmp "$replacementFixture/SKILL.md" "$source/SKILL.md"
              done
              for source in $externalSources; do
                cmp "$externalFixture/SKILL.md" "$source/SKILL.md"
                cmp "$externalFixture/references/contract.txt" "$source/references/contract.txt"
                mkdir projected
                ln -s "$source" projected/external-procedure
                test "$(bash projected/external-procedure/scripts/read-reference.sh)" \
                  = "$(cat "$externalFixture/references/contract.txt")"
                rm -r projected
              done
              touch $out
            '';
      }
    )
  ];
}
