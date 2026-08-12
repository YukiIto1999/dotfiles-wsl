{
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
  expected = builtins.fromJSON (builtins.readFile ../fixtures/client-contract.json);
  agentConfig = hostConfig.dotfiles.agents;
  inherit (agentConfig) clients;
  variantClients = variantConfig.dotfiles.agents.clients;
  wrapperDirectory = ".local/share/dotfiles-agent/bin";
  runtimeWrapperModeVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      {
        dotfiles.agents.clients.antigravity.runtimeWrapperMode = lib.mkForce "managed";
        dotfiles.agents.clients.codex.runtimeWrapperMode = lib.mkForce "unsupported";
      }
    ]).config;
  runtimeWrapperModeVariantHome =
    runtimeWrapperModeVariantConfig.home-manager.users.${hostConfig.dotfiles.host.username};

  projectManagedFile =
    file:
    builtins.removeAttrs file [
      "seedMigrationCommand"
      "source"
    ]
    // lib.optionalAttrs (file.seedMigrationCommand != null) {
      seedMigrationCommand = lib.getName file.seedMigrationCommand;
    };
  projectClient = client: {
    inherit (client)
      binary
      capabilityManagedFiles
      rulesDestination
      skillsDestination
      versionArgs
      ;
    definitions = {
      mode = client.definitionMode;
      destination = client.definitionsDestination;
      format = client.definitionFormat;
      names = builtins.attrNames client.definitions;
    };
    capabilities = {
      lsp = client.lspMode;
      telemetry = client.telemetryMode;
      agentmemory = client.agentmemoryMode;
    };
    gateway = {
      inherit (client.gatewayConfig) format managedFile;
    };
    managedFiles = lib.mapAttrs (_: projectManagedFile) client.managedFiles;
    inherit (client) install;
  };
  actualContract = lib.mapAttrs (_: projectClient) clients;

  clientOptions = builtins.removeAttrs (
    hostOptions.dotfiles.agents.clients.type.nestedTypes.elemType.getSubOptions
    [ ]
  ) [ "_module" ];
  managedFileOptions = builtins.removeAttrs (
    clientOptions.managedFiles.type.nestedTypes.elemType.getSubOptions
    [ ]
  ) [ "_module" ];
  capabilityManagedFileOptions = builtins.removeAttrs (
    clientOptions.capabilityManagedFiles.type.getSubOptions
    [ ]
  ) [ "_module" ];
  optionMetadata = {
    enabled = {
      type = hostOptions.dotfiles.agents.enabled.type.name;
      elementType = hostOptions.dotfiles.agents.enabled.type.nestedTypes.elemType.name;
      hasDefault = hostOptions.dotfiles.agents.enabled ? default;
    };
    runtime.ledgerRetentionDays = {
      type = hostOptions.dotfiles.agents.runtime.ledgerRetentionDays.type.name;
      default = hostOptions.dotfiles.agents.runtime.ledgerRetentionDays.default;
    };
    shared = lib.mapAttrs (_: option: {
      type = option.type.name;
      internal = option.internal or false;
      readOnly = option.readOnly or false;
    }) hostOptions.dotfiles.agents.shared;
    clients = {
      type = hostOptions.dotfiles.agents.clients.type.name;
      elementType = hostOptions.dotfiles.agents.clients.type.nestedTypes.elemType.name;
      internal = hostOptions.dotfiles.agents.clients.internal or false;
      hasDefault = hostOptions.dotfiles.agents.clients ? default;
    };
    clientExecutables = {
      type = hostOptions.dotfiles.agents.clientExecutables.type.name;
      elementType = hostOptions.dotfiles.agents.clientExecutables.type.nestedTypes.elemType.name;
      internal = hostOptions.dotfiles.agents.clientExecutables.internal or false;
      readOnly = hostOptions.dotfiles.agents.clientExecutables.readOnly or false;
    };
    client = lib.mapAttrs (_: option: option.type.name) clientOptions;
    managedFile = lib.mapAttrs (_: option: option.type.name) managedFileOptions;
    capabilityManagedFile = lib.mapAttrs (_: option: option.type.name) capabilityManagedFileOptions;
  };
  runtimeWrapperModeMetadata =
    if clientOptions ? runtimeWrapperMode then
      {
        type = clientOptions.runtimeWrapperMode.type.name;
        hasDefault = clientOptions.runtimeWrapperMode ? default;
      }
    else
      null;
  expectedRuntimeWrapperModeMetadata = {
    type = "enum";
    hasDefault = false;
  };
  expectedOptionMetadata = {
    enabled = {
      type = "listOf";
      elementType = "str";
      hasDefault = false;
    };
    runtime.ledgerRetentionDays = {
      type = "positiveInt";
      default = 30;
    };
    shared = {
      rules = {
        type = "path";
        internal = true;
        readOnly = true;
      };
      skills = {
        type = "attrsOf";
        internal = true;
        readOnly = true;
      };
      definitions = {
        type = "attrsOf";
        internal = true;
        readOnly = true;
      };
    };
    clients = {
      type = "attrsOf";
      elementType = "submodule";
      internal = true;
      hasDefault = true;
    };
    clientExecutables = {
      type = "attrsOf";
      elementType = "str";
      internal = true;
      readOnly = true;
    };
    client = {
      agentmemoryMode = "enum";
      binary = "str";
      capabilityManagedFiles = "submodule";
      definitionFormat = "nullOr";
      definitionMode = "enum";
      definitions = "attrsOf";
      definitionsDestination = "nullOr";
      gatewayConfig = "submodule";
      install = "either";
      lspMode = "enum";
      managedFiles = "attrsOf";
      rulesDestination = "str";
      runtimeWrapperMode = "enum";
      skillsDestination = "str";
      telemetryMode = "enum";
      versionArgs = "listOf";
    };
    managedFile = {
      deployment = "enum";
      destination = "str";
      format = "enum";
      seedMigrationCommand = "nullOr";
      source = "path";
    };
    capabilityManagedFile = {
      agentmemory = "nullOr";
      lsp = "nullOr";
      telemetry = "nullOr";
    };
  };

  fixtureSource = ../shared/AGENTS.md;
  fixtureSeedMigrationCommand = pkgs.writeShellScriptBin "dotfiles-migrate-codex-config" "exit 0";
  agentContract = import ../impl/contract.nix { inherit lib; };
  fixtureDefinitions = lib.genAttrs expected.clients.claude.definitions.names (_: fixtureSource);
  expectedRuntimeWrapperModes = {
    antigravity = "unsupported";
    claude = "managed";
    codex = "managed";
    opencode = "managed";
  };
  candidateClients = lib.mapAttrs (name: client: {
    inherit (client)
      binary
      capabilityManagedFiles
      rulesDestination
      skillsDestination
      versionArgs
      install
      ;
    runtimeWrapperMode = expectedRuntimeWrapperModes.${name};
    definitionMode = client.definitions.mode;
    definitionsDestination = client.definitions.destination;
    definitionFormat = client.definitions.format;
    definitions = lib.genAttrs client.definitions.names (_: fixtureSource);
    gatewayConfig = client.gateway // {
      source = fixtureSource;
    };
    managedFiles = lib.mapAttrs (
      _: file:
      builtins.removeAttrs file [ "seedMigrationCommand" ]
      // {
        source = fixtureSource;
      }
      // lib.optionalAttrs (file ? seedMigrationCommand) {
        seedMigrationCommand = fixtureSeedMigrationCommand;
      }
    ) client.managedFiles;
    lspMode = client.capabilities.lsp;
    telemetryMode = client.capabilities.telemetry;
    agentmemoryMode = client.capabilities.agentmemory;
  }) expected.clients;
  baseCandidate = {
    enabled = expected.required;
    inherit (agentConfig) runtime;
    shared = {
      rules = fixtureSource;
      skills.fixture = fixtureSource;
      definitions = fixtureDefinitions;
    };
    clients = candidateClients;
  };
  missingRuntimeWrapperModeCandidate = baseCandidate // {
    clients = baseCandidate.clients // {
      claude = builtins.removeAttrs baseCandidate.clients.claude [ "runtimeWrapperMode" ];
    };
  };
  expectedClientExecutables = lib.mapAttrs (
    _: client: "${hostConfig.dotfiles.host.homeDir}/.local/bin/${client.binary}"
  ) clients;
  mutateRuntimeTimer =
    timerName: update:
    baseCandidate
    // {
      runtime = baseCandidate.runtime // {
        timers = baseCandidate.runtime.timers // {
          ${timerName} = baseCandidate.runtime.timers.${timerName} // update;
        };
      };
    };
  maximumTimerName = lib.concatStrings (lib.replicate 247 "a");
  oversizedTimerName = lib.concatStrings (lib.replicate 248 "a");

  evalContract =
    candidate:
    lib.evalModules {
      modules = [
        ({ config, ... }: {
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
          config.dotfiles.agents = candidate;
          config.assertions = agentContract.assertionsFor config.dotfiles.agents;
        })
      ];
    };
  contractIsValid =
    candidate:
    let
      attempted = builtins.tryEval (
        let
          evaluated = evalContract candidate;
          evaluatedContract = builtins.removeAttrs evaluated.config.dotfiles.agents [
            "agentResource"
            "agentWorktree"
            "stateRoot"
          ];
          contractWithoutPackages = evaluatedContract // {
            clients = lib.mapAttrs (
              _: client:
              client
              // {
                managedFiles = lib.mapAttrs (
                  _: file: builtins.removeAttrs file [ "seedMigrationCommand" ]
                ) client.managedFiles;
              }
            ) evaluatedContract.clients;
          };
        in
        builtins.deepSeq contractWithoutPackages (
          builtins.all (assertion: assertion.assertion) evaluated.config.assertions
        )
      );
    in
    attempted.success && attempted.value;
  failedContractMessages =
    candidate:
    map (entry: entry.message) (
      builtins.filter (entry: !entry.assertion) (evalContract candidate).config.assertions
    );
  requiredStringChecksFor =
    candidate: agentContract.requiredStringChecksFor (evalContract candidate).config.dotfiles.agents;
  mutateClient =
    name: update:
    baseCandidate
    // {
      clients = baseCandidate.clients // {
        ${name} = baseCandidate.clients.${name} // update;
      };
    };
  renameClient =
    oldName: newName:
    baseCandidate
    // {
      enabled = map (name: if name == oldName then newName else name) baseCandidate.enabled;
      clients = builtins.removeAttrs baseCandidate.clients [ oldName ] // {
        ${newName} = baseCandidate.clients.${oldName};
      };
    };
  mutateManagedDestination =
    clientName: fileId: destination:
    mutateClient clientName {
      managedFiles = baseCandidate.clients.${clientName}.managedFiles // {
        ${fileId} = baseCandidate.clients.${clientName}.managedFiles.${fileId} // {
          inherit destination;
        };
      };
    };
  emptyBinaryCandidate = mutateClient "claude" { binary = ""; };
  invalidBinaryCandidates = map (binary: mutateClient "claude" { inherit binary; }) [
    "."
    ".."
    "bin/claude"
    "bad name"
  ];
  duplicateBinaryCandidate = mutateClient "codex" {
    binary = baseCandidate.clients.claude.binary;
  };
  binaryCandidateOfLength =
    length:
    mutateClient "claude" {
      binary = lib.concatStrings (lib.replicate length "a");
    };
  emptyInstallScriptUrlCandidate = mutateClient "claude" {
    install = baseCandidate.clients.claude.install // {
      scriptUrl = "";
    };
  };
  emptyInstallRepoCandidate = mutateClient "codex" {
    install = baseCandidate.clients.codex.install // {
      repo = "";
    };
  };
  emptyInstallAarch64AssetCandidate = mutateClient "codex" {
    install = baseCandidate.clients.codex.install // {
      releaseByArch = baseCandidate.clients.codex.install.releaseByArch // {
        aarch64 = baseCandidate.clients.codex.install.releaseByArch.aarch64 // {
          asset = "";
        };
      };
    };
  };
  emptyInstallX86AssetCandidate = mutateClient "codex" {
    install = baseCandidate.clients.codex.install // {
      releaseByArch = baseCandidate.clients.codex.install.releaseByArch // {
        x86_64 = baseCandidate.clients.codex.install.releaseByArch.x86_64 // {
          asset = "";
        };
      };
    };
  };
  emptyInstallEntrypointCandidate = mutateClient "codex" {
    install = baseCandidate.clients.codex.install // {
      releaseByArch = baseCandidate.clients.codex.install.releaseByArch // {
        x86_64 = baseCandidate.clients.codex.install.releaseByArch.x86_64 // {
          entrypoint = "";
        };
      };
    };
  };
  packageTreeInstall = baseCandidate.clients.codex.install // {
    layout = "package-tree";
    releaseByArch = lib.mapAttrs (
      _: release: release // { entrypoint = "bin/codex"; }
    ) baseCandidate.clients.codex.install.releaseByArch;
    requiredPaths = {
      bin = {
        kind = "directory";
        executable = false;
      };
      "bin/codex" = {
        kind = "file";
        executable = true;
      };
    };
  };
  invalidInstallEntrypointCandidate =
    entrypoint:
    mutateClient "codex" {
      install = baseCandidate.clients.codex.install // {
        releaseByArch = baseCandidate.clients.codex.install.releaseByArch // {
          x86_64 = baseCandidate.clients.codex.install.releaseByArch.x86_64 // {
            inherit entrypoint;
          };
        };
      };
    };
  invalidRequiredPathCandidate =
    path:
    mutateClient "codex" {
      install = packageTreeInstall // {
        requiredPaths = packageTreeInstall.requiredPaths // {
          ${path} = {
            kind = "file";
            executable = false;
          };
        };
      };
    };
  requiredInstallNegativeEvalCaseNames = [
    "entrypoint-current-segment"
    "entrypoint-empty-segment"
    "invalid-kind"
    "legacy-asset-by-arch"
    "legacy-binary-in-archive"
    "required-path-current-segment"
    "required-path-empty-segment"
  ];
  installNegativeEvalCases = {
    entrypoint-current-segment = invalidInstallEntrypointCandidate "bin/./codex";
    entrypoint-empty-segment = invalidInstallEntrypointCandidate "bin//codex";
    invalid-kind = mutateClient "claude" {
      install = baseCandidate.clients.claude.install // {
        kind = "invalid-kind";
      };
    };
    legacy-asset-by-arch = mutateClient "codex" {
      install = baseCandidate.clients.codex.install // {
        assetByArch = {
          x86_64 = "legacy-x86_64.tar.gz";
          aarch64 = "legacy-aarch64.tar.gz";
        };
      };
    };
    legacy-binary-in-archive = mutateClient "codex" {
      install = baseCandidate.clients.codex.install // {
        binaryInArchive = "codex";
      };
    };
    required-path-current-segment = invalidRequiredPathCandidate "bin/./share";
    required-path-empty-segment = invalidRequiredPathCandidate "bin//share";
  };
  unexpectedlyValidInstallNegativeEvalCases = builtins.attrNames (
    lib.filterAttrs (_: contractIsValid) installNegativeEvalCases
  );
  invalidInstallEntrypointCandidates = map invalidInstallEntrypointCandidate [
    ""
    "/codex"
    "../codex"
    "bin/../codex"
    "bin//codex"
    "bin/./codex"
  ];
  invalidRequiredPathCandidates = map invalidRequiredPathCandidate [
    ""
    "/share/codex"
    "../share/codex"
    "share/../codex"
    "bin//share"
    "bin/./share"
  ];
  nonSeedMigrationCandidate = mutateClient "opencode" {
    managedFiles = baseCandidate.clients.opencode.managedFiles // {
      config = baseCandidate.clients.opencode.managedFiles.config // {
        seedMigrationCommand = fixtureSeedMigrationCommand;
      };
    };
  };
  invalidRulesDestinationCandidate = mutateClient "claude" {
    rulesDestination = "../AGENTS.md";
  };
  invalidSkillsDestinationCandidate = mutateClient "claude" {
    skillsDestination = ".claude//skills";
  };
  invalidDefinitionsDestinationCandidate = mutateClient "claude" {
    definitionsDestination = "/tmp/agents";
  };
  invalidMultipleSharedDestinationsCandidate = mutateClient "claude" {
    rulesDestination = "../AGENTS.md";
    skillsDestination = ".claude//skills";
  };
in
{
  agent-client-roster =
    assert expected.required != [ ];
    assert clients != { };
    assert lib.sort builtins.lessThan hostConfig.dotfiles.agents.enabled == expected.required;
    assert lib.sort builtins.lessThan (builtins.attrNames clients) == expected.required;
    assert variantConfig.dotfiles.agents.enabled == expected.required;
    assert lib.sort builtins.lessThan (builtins.attrNames variantClients) == expected.required;
    assert actualContract == expected.clients;
    assert optionMetadata == expectedOptionMetadata;
    assert runtimeWrapperModeMetadata == expectedRuntimeWrapperModeMetadata;
    assert lib.mapAttrs (_: client: client.runtimeWrapperMode) clients == expectedRuntimeWrapperModes;
    assert !contractIsValid missingRuntimeWrapperModeCandidate;
    assert !contractIsValid (mutateClient "claude" { runtimeWrapperMode = "invalid"; });
    assert builtins.attrNames agentConfig.clientExecutables == builtins.attrNames clients;
    assert agentConfig.clientExecutables == expectedClientExecutables;
    assert
      runtimeWrapperModeVariantHome.home.file."${wrapperDirectory}/${clients.antigravity.binary}".executable;
    assert !(runtimeWrapperModeVariantHome.home.file ? "${wrapperDirectory}/${clients.codex.binary}");
    assert contractIsValid baseCandidate;
    assert !contractIsValid (mutateRuntimeTimer "autoupdate" { name = ""; });
    assert !contractIsValid (mutateRuntimeTimer "projectCacheGc" { name = "bad/name"; });
    assert !contractIsValid (mutateRuntimeTimer "resourceReaper" { name = "bad name"; });
    assert !contractIsValid (mutateRuntimeTimer "resourceReaper" { name = ".hidden"; });
    assert contractIsValid (mutateRuntimeTimer "autoupdate" { name = maximumTimerName; });
    assert !contractIsValid (mutateRuntimeTimer "autoupdate" { name = oversizedTimerName; });
    assert !contractIsValid (mutateRuntimeTimer "autoupdate" { onCalendar = ""; });
    assert !contractIsValid (mutateRuntimeTimer "autoupdate" { onCalendar = "   "; });
    assert !contractIsValid (mutateRuntimeTimer "autoupdate" { onCalendar = "daily\n"; });
    assert contractIsValid (mutateRuntimeTimer "autoupdate" { onCalendar = "*-*-* 00/6:00:00"; });
    assert !contractIsValid (baseCandidate // { clients = { }; });
    assert !contractIsValid (renameClient "codex" ".");
    assert !contractIsValid (renameClient "codex" "..");
    assert !contractIsValid (renameClient "codex" "bad/name");
    assert !contractIsValid (renameClient "codex" "bad name");
    assert builtins.elem "agent client IDs must be safe basenames: ." (
      failedContractMessages (renameClient "codex" ".")
    );
    assert builtins.all (valid: valid) (builtins.attrValues (requiredStringChecksFor baseCandidate));
    assert !contractIsValid (baseCandidate // { enabled = [ "claude" ]; });
    assert !contractIsValid (mutateClient "claude" { definitionFormat = "toml"; });
    assert
      !contractIsValid (
        mutateClient "antigravity" {
          definitionsDestination = ".gemini/agents";
          definitionFormat = "frontmatter-markdown";
          definitions.fixture = fixtureSource;
        }
      );
    assert !contractIsValid (mutateClient "codex" { definitionFormat = null; });
    assert
      !contractIsValid (
        mutateClient "opencode" {
          managedFiles = builtins.removeAttrs baseCandidate.clients.opencode.managedFiles [ "config" ];
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          managedFiles = baseCandidate.clients.codex.managedFiles // {
            user = baseCandidate.clients.codex.managedFiles.user // {
              destination = baseCandidate.clients.claude.managedFiles.user-settings.destination;
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          managedFiles = baseCandidate.clients.codex.managedFiles // {
            user = baseCandidate.clients.codex.managedFiles.user // {
              destination = baseCandidate.clients.opencode.managedFiles.config.destination;
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateManagedDestination "codex" "user" ".config/opencode/../opencode/opencode.json"
      );
    assert !contractIsValid (mutateManagedDestination "antigravity" "mcp" "/tmp/antigravity.json");
    assert !contractIsValid (mutateManagedDestination "opencode" "config" ".config//opencode.json");
    assert !contractIsValid (mutateManagedDestination "opencode" "config" ".config/./opencode.json");
    assert !contractIsValid (mutateManagedDestination "opencode" "config" ".config/../opencode.json");
    assert !contractIsValid (mutateManagedDestination "codex" "user" "../outside-home.toml");
    assert !contractIsValid (mutateManagedDestination "codex" "system" "../outside-etc.toml");
    assert !contractIsValid invalidRulesDestinationCandidate;
    assert builtins.elem
      "agent shared destinations must be canonical home-relative paths: claude/rulesDestination (../AGENTS.md)"
      (failedContractMessages invalidRulesDestinationCandidate);
    assert !contractIsValid invalidSkillsDestinationCandidate;
    assert builtins.elem
      "agent shared destinations must be canonical home-relative paths: claude/skillsDestination (.claude//skills)"
      (failedContractMessages invalidSkillsDestinationCandidate);
    assert !contractIsValid invalidDefinitionsDestinationCandidate;
    assert builtins.elem
      "agent shared destinations must be canonical home-relative paths: claude/definitionsDestination (/tmp/agents)"
      (failedContractMessages invalidDefinitionsDestinationCandidate);
    assert builtins.elem
      "agent shared destinations must be canonical home-relative paths: claude/rulesDestination (../AGENTS.md), claude/skillsDestination (.claude//skills)"
      (failedContractMessages invalidMultipleSharedDestinationsCandidate);
    assert !contractIsValid (mutateClient "antigravity" { lspMode = "supported"; });
    assert
      !contractIsValid (
        mutateClient "antigravity" {
          capabilityManagedFiles.lsp = "mcp";
        }
      );
    assert
      !contractIsValid (
        mutateClient "opencode" {
          managedFiles = builtins.removeAttrs baseCandidate.clients.opencode.managedFiles [
            "agentmemory-plugin"
          ];
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          capabilityManagedFiles.agentmemory = null;
        }
      );
    assert !contractIsValid emptyBinaryCandidate;
    assert builtins.all (candidate: !contractIsValid candidate) invalidBinaryCandidates;
    assert !contractIsValid duplicateBinaryCandidate;
    assert builtins.elem "agent client binaries must be unique" (
      failedContractMessages duplicateBinaryCandidate
    );
    assert contractIsValid (binaryCandidateOfLength 127);
    assert contractIsValid (binaryCandidateOfLength 128);
    assert !contractIsValid (binaryCandidateOfLength 129);
    assert !contractIsValid (mutateClient "codex" { versionArgs = [ ]; });
    assert !contractIsValid (mutateClient "codex" { versionArgs = [ "" ]; });
    assert !contractIsValid (mutateClient "claude" { rulesDestination = ""; });
    assert !contractIsValid (mutateClient "claude" { skillsDestination = ""; });
    assert !contractIsValid (mutateClient "claude" { definitionsDestination = ""; });
    assert
      !contractIsValid (
        mutateClient "claude" {
          definitions = baseCandidate.clients.claude.definitions // {
            "" = fixtureSource;
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "antigravity" {
          managedFiles.mcp = baseCandidate.clients.antigravity.managedFiles.mcp // {
            destination = "";
          };
        }
      );
    assert
      !(requiredStringChecksFor (
        mutateClient "antigravity" {
          gatewayConfig = baseCandidate.clients.antigravity.gatewayConfig // {
            managedFile = "";
          };
        }
      )).gatewayManagedFileReferences;
    assert
      !(requiredStringChecksFor (
        mutateClient "claude" {
          capabilityManagedFiles = baseCandidate.clients.claude.capabilityManagedFiles // {
            lsp = "";
          };
        }
      )).capabilityManagedFileReferences;
    assert
      !(requiredStringChecksFor (
        mutateClient "antigravity" {
          managedFiles = baseCandidate.clients.antigravity.managedFiles // {
            "" = {
              source = fixtureSource;
              format = "json";
              deployment = "home";
              destination = ".gemini/antigravity-cli/empty-id.json";
            };
          };
        }
      )).managedFileIds;
    assert
      !(requiredStringChecksFor (
        baseCandidate // { enabled = [ "" ] ++ builtins.tail baseCandidate.enabled; }
      )).enabledIds;
    assert
      !(requiredStringChecksFor (
        baseCandidate
        // {
          clients = baseCandidate.clients // {
            "" = baseCandidate.clients.antigravity;
          };
        }
      )).clientIds;
    assert
      !contractIsValid (
        baseCandidate
        // {
          shared = baseCandidate.shared // {
            skills = baseCandidate.shared.skills // {
              "" = fixtureSource;
            };
          };
        }
      );
    assert
      !contractIsValid (
        baseCandidate
        // {
          shared = baseCandidate.shared // {
            definitions = baseCandidate.shared.definitions // {
              "" = fixtureSource;
            };
          };
        }
      );
    assert !contractIsValid emptyInstallScriptUrlCandidate;
    assert lib.any (lib.hasInfix "installScriptUrls (claude)") (
      failedContractMessages emptyInstallScriptUrlCandidate
    );
    assert !contractIsValid emptyInstallRepoCandidate;
    assert lib.any (lib.hasInfix "installRepositories (codex)") (
      failedContractMessages emptyInstallRepoCandidate
    );
    assert !contractIsValid emptyInstallAarch64AssetCandidate;
    assert lib.any (lib.hasInfix "installAssetsAarch64 (codex)") (
      failedContractMessages emptyInstallAarch64AssetCandidate
    );
    assert !contractIsValid emptyInstallX86AssetCandidate;
    assert lib.any (lib.hasInfix "installAssetsX86_64 (codex)") (
      failedContractMessages emptyInstallX86AssetCandidate
    );
    assert !contractIsValid emptyInstallEntrypointCandidate;
    assert lib.any (lib.hasInfix "installEntrypointsX86_64 (codex)") (
      failedContractMessages emptyInstallEntrypointCandidate
    );
    assert lib.assertMsg (
      builtins.attrNames installNegativeEvalCases == requiredInstallNegativeEvalCaseNames
    ) "agent install negative eval regression cases must be explicit and complete";
    assert lib.assertMsg (unexpectedlyValidInstallNegativeEvalCases == [ ]) (
      "invalid agent install evaluation succeeded: "
      + lib.concatStringsSep ", " unexpectedlyValidInstallNegativeEvalCases
    );
    assert builtins.all (candidate: !contractIsValid candidate) invalidInstallEntrypointCandidates;
    assert builtins.all (candidate: !contractIsValid candidate) invalidRequiredPathCandidates;
    assert baseCandidate.clients.codex.install.retainedReleases == 2;
    assert baseCandidate.clients.opencode.install.retainedReleases == 2;
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            retainedReleases = 1;
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            retainedReleases = 11;
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "claude" {
          install = baseCandidate.clients.claude.install // {
            updateOwner = "dotfiles";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            releaseByArch = baseCandidate.clients.codex.install.releaseByArch // {
              x86_64 = baseCandidate.clients.codex.install.releaseByArch.x86_64 // {
                unexpected = "untyped";
              };
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = packageTreeInstall // {
            requiredPaths."bin/codex" = packageTreeInstall.requiredPaths."bin/codex" // {
              unexpected = "untyped";
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "claude" {
          install = baseCandidate.clients.claude.install // {
            layout = "single-binary";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            updateOwner = "upstream-installer";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            layout = "upstream-managed";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            layout = "package-tree";
            requiredPaths = { };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = packageTreeInstall // {
            requiredPaths = {
              "bin/other" = {
                kind = "file";
                executable = true;
              };
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = packageTreeInstall // {
            requiredPaths."bin/codex" = {
              kind = "directory";
              executable = false;
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            requiredPaths.codex = {
              kind = "file";
              executable = true;
            };
          };
        }
      );
    assert !contractIsValid nonSeedMigrationCandidate;
    assert
      !contractIsValid (
        mutateClient "claude" {
          install = baseCandidate.clients.claude.install // {
            repo = "invalid/extra";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "claude" {
          install = baseCandidate.clients.claude.install // {
            unexpected = "untyped";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = {
            kind = "github-release";
            repo = "openai/codex";
            updateOwner = "dotfiles";
            layout = "single-binary";
            releaseByArch.x86_64 = {
              asset = "only-one-architecture.tar.gz";
              entrypoint = "codex";
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "claude" {
          managedFiles.managed-settings = baseCandidate.clients.claude.managedFiles.managed-settings // {
            owner = "untyped";
          };
        }
      );
    pkgs.runCommandLocal "check-agent-client-roster" { } "touch $out";
}
