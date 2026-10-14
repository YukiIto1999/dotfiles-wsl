{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        variantConfig,
        ...
      }:
      let
        agentContract = import ../impl/contract.nix { inherit lib; };
        agentConfig = hostConfig.dotfiles.agents;
        inherit (agentConfig) registry;
        adapterNames = builtins.attrNames registry;
        adapterDirectories = builtins.attrNames (
          lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../clients)
        );
        wrapperDirectory = ".local/share/dotfiles-agent/bin";
        variantHome = variantConfig.home-manager.users.${variantConfig.dotfiles.workstation.username};

        # 登録済み adapter の実値を出発点にし、固定済みの宣言の写しを持たない。評価済みの値が持つ
        # _module と derivation を外して、新しい評価へ定義として渡せる素の attrset にする
        fixtureSource = ../policy/AGENTS.md;
        fixtureSeedMigrationCommand = pkgs.writeShellScriptBin "dotfiles-migrate-fixture" "exit 0";
        plain =
          value:
          if lib.isDerivation value then
            value
          else if builtins.isAttrs value then
            lib.mapAttrs (_: plain) (builtins.removeAttrs value [ "_module" ])
          else if builtins.isList value then
            map plain value
          else
            value;
        neutralClient =
          client:
          client
          // {
            subagents = lib.mapAttrs (
              _: branch:
              branch
              // lib.optionalAttrs (branch ? sources) {
                sources = lib.mapAttrs (_: _: fixtureSource) branch.sources;
              }
            ) client.subagents;
            gatewayConfig = client.gatewayConfig // {
              source = fixtureSource;
            };
            managedFiles = lib.mapAttrs (
              _: file:
              file
              // {
                source = fixtureSource;
              }
              // lib.optionalAttrs (file.seedMigrationCommand != null) {
                seedMigrationCommand = fixtureSeedMigrationCommand;
              }
            ) client.managedFiles;
          };
        baseCandidate = {
          enabled = adapterNames;
          runtime = plain agentConfig.runtime;
          supply = plain agentConfig.supply;
          shared = {
            rules = fixtureSource;
            skills.fixture = fixtureSource;
            subagents = lib.genAttrs (builtins.attrNames agentConfig.shared.subagents) (_: fixtureSource);
            routing = {
              subagentSkills = [ ];
              subagentHandoffs = [ ];
            };
          };
          clients = lib.mapAttrs (_: client: plain (neutralClient client)) registry;
        };

        evalContract =
          candidate:
          lib.evalModules {
            modules = [
              (
                { config, ... }:
                {
                  options.dotfiles.agents = agentContract.options;
                  options.assertions = lib.mkOption {
                    type = lib.types.listOf (
                      lib.types.submodule {
                        options = {
                          assertion = lib.mkOption { type = lib.types.bool; };
                          message = lib.mkOption { type = lib.types.str; };
                        };
                      }
                    );
                    default = [ ];
                  };
                  config.dotfiles.agents = builtins.removeAttrs candidate [ "clients" ] // {
                    registry = candidate.clients;
                    clients = lib.genAttrs (builtins.filter (
                      name: builtins.hasAttr name candidate.clients
                    ) candidate.enabled) (name: config.dotfiles.agents.registry.${name});
                  };
                  config.assertions = agentContract.assertionsFor config.dotfiles.agents;
                }
              )
            ];
          };
        contractIsValid =
          candidate:
          let
            attempted = builtins.tryEval (
              let
                evaluated = evalContract candidate;
                contract = evaluated.config.dotfiles.agents;
                withoutSeedCommands = lib.mapAttrs (
                  _: client:
                  client
                  // {
                    managedFiles = lib.mapAttrs (
                      _: file: builtins.removeAttrs file [ "seedMigrationCommand" ]
                    ) client.managedFiles;
                  }
                ) contract.registry;
                typedInputs = lib.mapAttrs (name: _: contract.${name}) (
                  builtins.removeAttrs candidate [ "clients" ]
                );
              in
              builtins.deepSeq typedInputs (
                builtins.deepSeq withoutSeedCommands (
                  builtins.all (assertion: assertion.assertion) evaluated.config.assertions
                )
              )
            );
          in
          attempted.success && attempted.value;

        mutateClient =
          name: update:
          baseCandidate
          // {
            clients = baseCandidate.clients // {
              ${name} = baseCandidate.clients.${name} // update;
            };
          };
        # 一つの枝を丸ごと別の値へ置き換える。attrTag は枝の追加ではなく置換だけを許す
        replaceBranch =
          name: field: value:
          mutateClient name { ${field} = value; };
        renameClient =
          oldName: newName:
          baseCandidate
          // {
            enabled = map (name: if name == oldName then newName else name) baseCandidate.enabled;
            clients = builtins.removeAttrs baseCandidate.clients [ oldName ] // {
              ${newName} = baseCandidate.clients.${oldName};
            };
          };
        mutateTimer =
          timerName: update:
          baseCandidate
          // {
            runtime = baseCandidate.runtime // {
              timers = baseCandidate.runtime.timers // {
                ${timerName} = baseCandidate.runtime.timers.${timerName} // update;
              };
            };
          };
        mutateManagedFile =
          clientName: fileId: update:
          mutateClient clientName {
            managedFiles = baseCandidate.clients.${clientName}.managedFiles // {
              ${fileId} = baseCandidate.clients.${clientName}.managedFiles.${fileId} // update;
            };
          };
        renderedSubagents = name: baseCandidate.clients.${name}.subagents.rendered;
        maximumTimerName = lib.concatStrings (lib.replicate 247 "a");
        oversizedTimerName = lib.concatStrings (lib.replicate 248 "a");

        rejected = candidates: builtins.all (candidate: !contractIsValid candidate) candidates;
      in
      {
        agent-client-contract =
          # adapter の登録は clients/ の directory と一対一で、採用集合とは別に保たれる
          assert adapterNames == adapterDirectories;
          assert builtins.attrNames agentConfig.clients == lib.sort builtins.lessThan agentConfig.enabled;
          assert builtins.attrNames agentConfig.clientExecutables == builtins.attrNames agentConfig.clients;
          assert
            builtins.attrNames agentConfig.clientExecutionDependencies
            == builtins.attrNames agentConfig.clients;
          assert lib.all (
            name:
            agentConfig.clientExecutables.${name}
            == "${agentConfig.supply.root}/${name}/profile/bin/${agentConfig.clients.${name}.binary}"
          ) (builtins.attrNames agentConfig.clients);
          # 公開 command は PATH の前に置く wrapper だけで、runtime の対応なしでも native profile を PATH へ出さない
          assert lib.all (
            name:
            variantHome.home.file
              ? "${wrapperDirectory}/${variantConfig.dotfiles.agents.clients.${name}.binary}"
          ) (builtins.attrNames variantConfig.dotfiles.agents.clients);
          # 正しい宣言は構築を通り、対応形式の枝、必須値、参照の不整合は構築で拒否される
          assert contractIsValid baseCandidate;
          assert contractIsValid (baseCandidate // { enabled = [ (builtins.head adapterNames) ]; });
          assert !contractIsValid (baseCandidate // { enabled = [ "missing" ]; });
          assert !contractIsValid (baseCandidate // { enabled = [ ]; });
          assert !contractIsValid (baseCandidate // { automaticUpdates.clients = [ "missing" ]; });
          assert contractIsValid (
            baseCandidate
            // {
              enabled = [ "omp" ];
              automaticUpdates.clients = [ "omp" ];
            }
          );
          assert !contractIsValid (baseCandidate // { clients = { }; });
          assert !contractIsValid (renameClient "codex" ".");
          assert !contractIsValid (renameClient "codex" "..");
          assert !contractIsValid (renameClient "codex" "bad/name");
          assert !contractIsValid (renameClient "codex" "bad name");
          # 廃止した供給と mode の field は、型が持たない option として拒否する
          assert rejected [
            (mutateClient "omp" { install.kind = "github-release"; })
            (mutateClient "omp" { runtimeWrapperMode = "managed"; })
            (mutateClient "omp" { lspMode = "supported"; })
            (mutateClient "omp" { capabilityManagedFiles.lsp = "lsp"; })
            (mutateClient "omp" { subagentMode = "rendered"; })
            (mutateClient "omp" { rulesDestination = ".omp/agent/AGENTS.md"; })
          ];
          # discriminated union の枝
          assert rejected [
            (replaceBranch "omp" "lsp" { enabled = { }; })
            (replaceBranch "omp" "lsp" {
              supported.managedFile = "lsp";
              unsupported = { };
            })
            (replaceBranch "omp" "lsp" { supported = { }; })
            (replaceBranch "omp" "lsp" { supported.managedFile = ""; })
            (replaceBranch "omp" "lsp" { supported.extra = "untyped"; })
            (replaceBranch "omp" "lsp" "supported")
            (replaceBranch "claude" "telemetry" { supported = { }; })
            (replaceBranch "claude" "projectMemory" { hooks = { }; })
            (replaceBranch "claude" "projectMemory" { unknown.managedFile = "managed-settings"; })
            (replaceBranch "omp" "runtime" { invalid = { }; })
            (replaceBranch "omp" "runtime" {
              managed = { };
              unsupported = { };
            })
            (replaceBranch "omp" "rules" { file = { }; })
            (replaceBranch "omp" "rules" { file.destination = ""; })
            (replaceBranch "omp" "rules" { sometimes = { }; })
            (replaceBranch "omp" "subagents" { rendered = { }; })
            (replaceBranch "omp" "subagents" { sometimes = { }; })
          ];
          assert contractIsValid (replaceBranch "claude" "rules" { embedded = { }; });
          assert contractIsValid (replaceBranch "omp" "lsp" { unsupported = { }; });
          assert contractIsValid (replaceBranch "omp" "projectMemory" { unsupported = { }; });
          # TOML の subagent は preload を表現できず、preload は frontmatter markdown の枝だけが選べる
          assert rejected [
            (replaceBranch "codex" "subagents" {
              declared = baseCandidate.clients.codex.subagents.declared // {
                skillProjection = "preload";
              };
            })
            (replaceBranch "codex" "subagents" {
              declared = baseCandidate.clients.codex.subagents.declared // {
                format = "frontmatter-markdown";
              };
            })
            (replaceBranch "codex" "subagents" {
              native = {
                destination = ".codex/agents";
                sources = baseCandidate.clients.codex.subagents.declared.sources;
                skillProjection = "preload";
              };
            })
            (replaceBranch "omp" "subagents" {
              rendered = (renderedSubagents "omp") // {
                skillProjection = "unsupported";
              };
            })
            (replaceBranch "omp" "subagents" {
              rendered = (renderedSubagents "omp") // {
                sources = { };
              };
            })
            (replaceBranch "omp" "subagents" {
              rendered = (renderedSubagents "omp") // {
                destination = "/tmp/agents";
              };
            })
            (replaceBranch "omp" "subagents" {
              rendered = (renderedSubagents "omp") // {
                format = "toml";
              };
            })
          ];
          assert contractIsValid (
            replaceBranch "omp" "subagents" {
              rendered = (renderedSubagents "omp") // {
                skillProjection = "dynamic";
              };
            }
          );
          assert contractIsValid (replaceBranch "omp" "subagents" { unsupported = { }; });
          # 枝の中の値と対応しない参照は、枝の形では表せないため構築の整合として拒否する
          assert !contractIsValid (replaceBranch "omp" "lsp" { supported.managedFile = "missing"; });
          assert !contractIsValid (replaceBranch "claude" "telemetry" { supported.managedFile = "missing"; });
          assert !contractIsValid (replaceBranch "codex" "projectMemory" { hooks.managedFile = "missing"; });
          assert
            !contractIsValid (
              mutateClient "claude" {
                gatewayConfig = baseCandidate.clients.claude.gatewayConfig // {
                  managedFile = "missing";
                };
              }
            );
          assert
            !contractIsValid (
              mutateClient "opencode" {
                managedFiles = builtins.removeAttrs baseCandidate.clients.opencode.managedFiles [ "config" ];
              }
            );
          # destination と識別子
          assert rejected [
            (replaceBranch "claude" "rules" { file.destination = "../AGENTS.md"; })
            (mutateClient "claude" { skillsDestination = ".claude//skills"; })
            (mutateClient "claude" { skillsDestination = ""; })
            (mutateManagedFile "codex" "user" { destination = "../outside-home.toml"; })
            (mutateManagedFile "codex" "system" { destination = "/etc/outside.toml"; })
            (mutateManagedFile "opencode" "config" { destination = ".config//opencode.json"; })
            (mutateManagedFile "opencode" "config" { destination = ".config/./opencode.json"; })
            (mutateManagedFile "antigravity" "mcp" { destination = ""; })
            (mutateManagedFile "codex" "user" {
              destination = baseCandidate.clients.claude.managedFiles.user-settings.destination;
            })
            (mutateManagedFile "claude" "managed-mcp" {
              destination = baseCandidate.clients.claude.managedFiles.managed-settings.destination;
            })
            (mutateManagedFile "opencode" "config" { seedMigrationCommand = fixtureSeedMigrationCommand; })
            (mutateManagedFile "claude" "managed-settings" { owner = "untyped"; })
            (mutateClient "claude" {
              managedFiles = baseCandidate.clients.claude.managedFiles // {
                "" = baseCandidate.clients.claude.managedFiles.managed-settings // {
                  destination = ".claude/empty-id.json";
                };
              };
            })
            (mutateClient "omp" {
              subagents.rendered = (renderedSubagents "omp") // {
                sources = (renderedSubagents "omp").sources // {
                  "" = fixtureSource;
                };
              };
            })
            (baseCandidate // { enabled = [ "" ] ++ builtins.tail baseCandidate.enabled; })
            (
              baseCandidate
              // {
                clients = baseCandidate.clients // {
                  "" = baseCandidate.clients.antigravity;
                };
              }
            )
            (
              baseCandidate
              // {
                shared = baseCandidate.shared // {
                  skills."" = fixtureSource;
                };
              }
            )
            (
              baseCandidate
              // {
                shared = baseCandidate.shared // {
                  subagents."" = fixtureSource;
                };
              }
            )
          ];
          # binary と供給 package
          assert rejected [
            (mutateClient "claude" { binary = ""; })
            (mutateClient "claude" { binary = "."; })
            (mutateClient "claude" { binary = ".."; })
            (mutateClient "claude" { binary = "bin/claude"; })
            (mutateClient "claude" { binary = "bad name"; })
            (mutateClient "codex" { binary = baseCandidate.clients.claude.binary; })
            (mutateClient "codex" { versionArgs = [ ]; })
            (mutateClient "codex" { versionArgs = [ "" ]; })
            (mutateClient "claude" { supply.package = ""; })
            (mutateClient "claude" { supply.package = "bad name"; })
            (mutateClient "claude" { supply.package = "-leading-dash"; })
            (mutateClient "claude" { supply = { }; })
            (mutateClient "claude" {
              supply = {
                package = "claude-code";
                repo = "untyped/source";
              };
            })
            (mutateClient "codex" { supply.package = baseCandidate.clients.claude.supply.package; })
          ];
          assert contractIsValid (
            mutateClient "claude" { binary = lib.concatStrings (lib.replicate 255 "a"); }
          );
          assert
            !contractIsValid (mutateClient "claude" { binary = lib.concatStrings (lib.replicate 256 "a"); });
          # runtime timer
          assert rejected [
            (mutateTimer "autoupdate" { name = ""; })
            (mutateTimer "projectCacheGc" { name = "bad/name"; })
            (mutateTimer "projectCacheGc" { name = "bad name"; })
            (mutateTimer "projectCacheGc" { name = ".hidden"; })
            (mutateTimer "autoupdate" { name = oversizedTimerName; })
            (mutateTimer "autoupdate" { onCalendar = ""; })
            (mutateTimer "autoupdate" { onCalendar = "   "; })
            (mutateTimer "autoupdate" { onCalendar = "daily\n"; })
          ];
          assert contractIsValid (mutateTimer "autoupdate" { name = maximumTimerName; });
          assert contractIsValid (mutateTimer "autoupdate" { onCalendar = "*-*-* 00/6:00:00"; });
          pkgs.runCommandLocal "check-agent-client-contract" { } "touch $out";
      }
    )
  ];
}
