{
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  variantConfig,
  self,
  ...
}:

let
  expected = builtins.fromJSON (builtins.readFile ./fixtures/client-contract.json);
  clients = hostConfig.dotfiles.agents.clients;
  variantClients = variantConfig.dotfiles.agents.clients;
  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.host.username};
  artifacts = hostConfig.dotfiles.artifacts;
  artifactSource = id: artifacts.${id}.source;
  gatewayUrl = hostConfig.dotfiles.mcp.gateway.url;
  gatewayPort = hostConfig.dotfiles.mcp.gateway.port;
  variantGatewayUrl = variantConfig.dotfiles.mcp.gateway.url;
  roster = hostConfig.dotfiles.toolchain.lsp;
  installAgents = hostConfig.dotfiles.commands.installAgents;
  installAgentsExe = lib.getExe installAgents;
  runtime = import ./runtime/package.nix {
    inherit lib pkgs;
    agentWorktreeCommand = lib.getExe hostConfig.dotfiles.commands.agentWorktree;
  };
  fakeNix = pkgs.writeShellScript "fake-nix-command" ''
    printf '%s\0' "$@" > "$ARG_CAPTURE"
  '';
  fakeGit = pkgs.writeShellScript "fake-git-command" ''
    printf '%s\0' "$@" > "$ARG_CAPTURE"
    pwd -P > "$PWD_CAPTURE"
    for argument in "$@"; do
      if [ "$argument" = dotfiles-agent-managed-worktree ]; then
        exec ${lib.getExe pkgs.git} "$@"
      fi
    done
  '';
  fakeAgentWorktree = pkgs.writeShellScript "fake-agent-worktree-command" ''
    printf '%s\0' "$@" > "$ARG_CAPTURE"
    pwd -P > "$PWD_CAPTURE"
    ${lib.getExe pkgs.git} config --get advice.detachedHead > "$CONFIG_CAPTURE" || true
  '';
  fixtureNixBuildShims = runtime.mkNixBuildShims {
    nixCommand = fakeNix;
    nixBuildCommand = fakeNix;
  };
  fixtureAgentShims = runtime.mkAgentShims {
    nixCommand = fakeNix;
    nixBuildCommand = fakeNix;
    gitCommand = fakeGit;
    worktreeCommand = fakeAgentWorktree;
  };
  wrapperDirectory = ".local/share/dotfiles-agent/bin";
  runtimeClientNames = builtins.filter (name: name != "antigravity" && clients.${name}.binary != "") (
    builtins.attrNames clients
  );

  withoutNulls = lib.filterAttrs (_: value: value != null);
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
    managedFiles = lib.mapAttrs (_: file: builtins.removeAttrs file [ "source" ]) client.managedFiles;
    install = withoutNulls client.install;
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
    client = lib.mapAttrs (_: option: option.type.name) clientOptions;
    managedFile = lib.mapAttrs (_: option: option.type.name) managedFileOptions;
    capabilityManagedFile = lib.mapAttrs (_: option: option.type.name) capabilityManagedFileOptions;
  };
  expectedOptionMetadata = {
    enabled = {
      type = "listOf";
      elementType = "str";
      hasDefault = false;
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
    client = {
      agentmemoryMode = "enum";
      binary = "str";
      capabilityManagedFiles = "submodule";
      definitionFormat = "nullOr";
      definitionMode = "enum";
      definitions = "attrsOf";
      definitionsDestination = "nullOr";
      gatewayConfig = "submodule";
      install = "submodule";
      lspMode = "enum";
      managedFiles = "attrsOf";
      rulesDestination = "str";
      skillsDestination = "str";
      telemetryMode = "enum";
      versionArgs = "listOf";
    };
    managedFile = {
      deployment = "enum";
      destination = "str";
      format = "enum";
      source = "path";
    };
    capabilityManagedFile = {
      agentmemory = "nullOr";
      lsp = "nullOr";
      telemetry = "nullOr";
    };
  };

  fixtureSource = ./shared/AGENTS.md;
  agentContract = import ./impl/contract.nix { inherit lib; };
  fixtureDefinitions = lib.genAttrs expected.clients.claude.definitions.names (_: fixtureSource);
  candidateClients = lib.mapAttrs (_: client: {
    inherit (client)
      binary
      capabilityManagedFiles
      rulesDestination
      skillsDestination
      versionArgs
      install
      ;
    definitionMode = client.definitions.mode;
    definitionsDestination = client.definitions.destination;
    definitionFormat = client.definitions.format;
    definitions = lib.genAttrs client.definitions.names (_: fixtureSource);
    gatewayConfig = client.gateway // {
      source = fixtureSource;
    };
    managedFiles = lib.mapAttrs (_: file: file // { source = fixtureSource; }) client.managedFiles;
    lspMode = client.capabilities.lsp;
    telemetryMode = client.capabilities.telemetry;
    agentmemoryMode = client.capabilities.agentmemory;
  }) expected.clients;
  baseCandidate = {
    enabled = expected.required;
    shared = {
      rules = fixtureSource;
      skills.fixture = fixtureSource;
      definitions = fixtureDefinitions;
    };
    clients = candidateClients;
  };

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
        in
        builtins.deepSeq evaluated.config.dotfiles.agents (
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
      assetByArch = baseCandidate.clients.codex.install.assetByArch // {
        aarch64 = "";
      };
    };
  };
  emptyInstallX86AssetCandidate = mutateClient "codex" {
    install = baseCandidate.clients.codex.install // {
      assetByArch = baseCandidate.clients.codex.install.assetByArch // {
        x86_64 = "";
      };
    };
  };
  emptyInstallArchiveBinaryCandidate = mutateClient "codex" {
    install = baseCandidate.clients.codex.install // {
      binaryInArchive = "";
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
        scriptUrl = "https://example.invalid/install.sh";
      };
    }
  ];
  losslessInstallAgents = pkgs.writeShellApplication {
    name = "check-lossless-install-agents";
    runtimeInputs = with pkgs; [
      bash
      curl
      jq
      gnutar
      gzip
      coreutils
    ];
    text =
      builtins.replaceStrings
        [
          "@installManifest@"
          "@versionArgsDecoder@"
        ]
        [
          losslessInstallManifest
          (builtins.readFile ./impl/version-args.sh)
        ]
        (builtins.readFile ./impl/install-agents.sh);
  };
  losslessInstallAgentsExe = lib.getExe losslessInstallAgents;

  expectedInstallManifest = map (name: {
    inherit name;
    inherit (expected.clients.${name}) binary versionArgs install;
  }) expected.required;
  agentmemoryHookCommand = name: "/run/current-system/sw/bin/agentmemory-hook-${name}";
  expectedHook =
    {
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
                command = agentmemoryHookCommand name;
              }
              // extra
            )
          ];
        }
        // lib.optionalAttrs (matcher != null) { inherit matcher; }
      )
    ];
  expectedClaudeHooks = {
    SessionStart = expectedHook { name = "session-start"; };
    UserPromptSubmit = expectedHook { name = "prompt-submit"; };
    PreToolUse = expectedHook {
      name = "pre-tool-use";
      matcher = "Edit|Write|Read|Glob|Grep";
    };
    PostToolUse = expectedHook { name = "post-tool-use"; };
    PostToolUseFailure = expectedHook { name = "post-tool-failure"; };
    PreCompact = expectedHook { name = "pre-compact"; };
    SubagentStart = expectedHook { name = "subagent-start"; };
    SubagentStop = expectedHook { name = "subagent-stop"; };
    Notification = expectedHook { name = "notification"; };
    TaskCompleted = expectedHook { name = "task-completed"; };
    Stop = expectedHook { name = "stop"; };
    SessionEnd = expectedHook { name = "session-end"; };
  };
  expectedCodexHooks = {
    SessionStart = expectedHook {
      name = "session-start";
      extra.statusMessage = "agentmemory: loading session context";
    };
    UserPromptSubmit = expectedHook { name = "prompt-submit"; };
    PreToolUse = expectedHook {
      name = "pre-tool-use";
      matcher = "Edit|Write|Read|Glob|Grep";
    };
    PostToolUse = expectedHook { name = "post-tool-use"; };
    PreCompact = expectedHook { name = "pre-compact"; };
    Stop = expectedHook { name = "stop"; };
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
        && artifact.deployedAt == "${hostConfig.dotfiles.host.homeDir}/${target}"
      else
        artifact.deployedAt == null
    );

  sharedDeploymentMatches = lib.all (
    clientName:
    let
      client = clients.${clientName};
      homePrefix = hostConfig.dotfiles.host.homeDir;
      rulesArtifact = artifacts."agents/${clientName}/rules";
      rulesMatch =
        rulesArtifact.source == normalizeSource hostConfig.dotfiles.agents.shared.rules
        && rulesArtifact.format == "markdown"
        && rulesArtifact.deployedAt == "${homePrefix}/${client.rulesDestination}";
      skillsMatch = lib.all (
        name:
        let
          artifact = artifacts."agents/${clientName}/skills/${name}";
        in
        artifact.source == normalizeSource hostConfig.dotfiles.agents.shared.skills.${name}
        && artifact.format == "directory"
        && artifact.deployedAt == "${homePrefix}/${client.skillsDestination}/${name}"
      ) (builtins.attrNames hostConfig.dotfiles.agents.shared.skills);
      definitionsMatch = lib.all (
        name:
        let
          suffix = if client.definitionFormat == "toml" then "toml" else "md";
          artifact = artifacts."agents/${clientName}/definitions/${name}";
          expectedFormat = if client.definitionFormat == "toml" then "toml" else "markdown";
        in
        homeConfig.home.file."${client.definitionsDestination}/${name}.${suffix}".source
        == normalizeSource client.definitions.${name}
        && artifact.source == normalizeSource client.definitions.${name}
        && artifact.format == expectedFormat
        && artifact.deployedAt == "${homePrefix}/${client.definitionsDestination}/${name}.${suffix}"
      ) (builtins.attrNames client.definitions);
    in
    homeConfig.home.file.${client.rulesDestination}.source
    == normalizeSource hostConfig.dotfiles.agents.shared.rules
    && lib.all (
      name:
      homeConfig.home.file."${client.skillsDestination}/${name}".source
      == normalizeSource hostConfig.dotfiles.agents.shared.skills.${name}
    ) (builtins.attrNames hostConfig.dotfiles.agents.shared.skills)
    && rulesMatch
    && skillsMatch
    && definitionsMatch
  ) (builtins.attrNames clients);

  expectedArtifactIds = lib.sort builtins.lessThan (
    lib.concatMap (
      clientName:
      let
        client = clients.${clientName};
      in
      [ "agents/${clientName}/rules" ]
      ++ map (name: "agents/${clientName}/skills/${name}") (
        builtins.attrNames hostConfig.dotfiles.agents.shared.skills
      )
      ++ map (name: "agents/${clientName}/definitions/${name}") (builtins.attrNames client.definitions)
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
    builtins.replaceStrings [ hostConfig.dotfiles.host.homeDir ] [ "$fixture/home" ]
      seedActivation;

  sharedDefinitionSources = builtins.attrValues hostConfig.dotfiles.agents.shared.definitions;
  claudeDefinitionSources = builtins.attrValues clients.claude.definitions;
  codexDefinitionSources = builtins.attrValues clients.codex.definitions;
  opencodeDefinitionSources = builtins.attrValues clients.opencode.definitions;
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
    assert contractIsValid baseCandidate;
    assert !contractIsValid (baseCandidate // { clients = { }; });
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
    assert builtins.elem "agent required semantic strings must be non-empty: binaries (claude)" (
      failedContractMessages emptyBinaryCandidate
    );
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
    assert !contractIsValid emptyInstallArchiveBinaryCandidate;
    assert lib.any (lib.hasInfix "installArchiveBinaries (codex)") (
      failedContractMessages emptyInstallArchiveBinaryCandidate
    );
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
            assetByArch.x86_64 = "only-one-architecture.tar.gz";
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

  agent-artifact-contract =
    assert variantConfig.dotfiles.mcp.gateway.port != gatewayPort;
    assert lib.count (package: package == installAgents) hostConfig.environment.systemPackages == 1;
    assert builtins.all managedDeploymentMatches managedRows;
    assert sharedDeploymentMatches;
    assert expectedArtifactIds == actualAgentArtifactIds;
    assert clients.claude.gatewayConfig.source == clients.claude.managedFiles.managed-mcp.source;
    assert clients.antigravity.gatewayConfig.source == clients.antigravity.managedFiles.mcp.source;
    assert clients.codex.gatewayConfig.source != clients.codex.managedFiles.system.source;
    assert clients.opencode.gatewayConfig.source != clients.opencode.managedFiles.config.source;
    assert lib.any (
      definition:
      lib.hasInfix "/agents/module.nix" (toString definition.file)
      && lib.elem hostConfig.dotfiles.containers.agentmemory.clients.hooks definition.value
    ) hostOptions.environment.systemPackages.definitionsWithLocations;
    assert
      clients.opencode.managedFiles.agentmemory-plugin.source
      == hostConfig.dotfiles.containers.agentmemory.clients.opencodePlugin;
    assert !(builtins.hasAttr "containers/agentmemory/opencode-capture" artifacts);
    assert lib.all (
      definition:
      lib.hasInfix "/agents/" (toString definition.file)
      && !lib.hasInfix "/containers/" (toString definition.file)
    ) hostOptions.dotfiles.agents.clients.definitionsWithLocations;
    pkgs.runCommandLocal "check-agent-artifact-contract"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.jq
          pkgs.remarshal
          pkgs.ripgrep
          pkgs.taplo
        ];
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

        cat > fake-version <<'SCRIPT'
        #!${pkgs.runtimeShell}
        printf '%s\0' "$@" > "$ARG_CAPTURE"
        SCRIPT
        chmod +x fake-version
        export ARG_CAPTURE=$PWD/version-args
        source ${./impl/version-args.sh}
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
          clients.claude.managedFiles.${clients.claude.capabilityManagedFiles.agentmemory}.source
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
          clients.codex.managedFiles.${clients.codex.capabilityManagedFiles.agentmemory}.source
        }
        remarshal -if toml -of json "$codexCapabilities" \
          | jq --exit-status \
            --argjson hooks ${lib.escapeShellArg (builtins.toJSON expectedCodexHooks)} '
            .hooks == $hooks
          ' > /dev/null

        grep -Fq 'skill の runtime drift は検査しない' ${self}/agents/shared/AGENTS.md
        grep -Fq 'managed file の runtime drift は検査しない' ${self}/docs/architecture/ai-tooling.md

        jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
          '. == {mcpServers: {gateway: {type: "http", url: $expected}}}' \
          ${clients.claude.gatewayConfig.source} > /dev/null
        jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
          '. == {mcpServers: {gateway: {serverUrl: $expected}}}' \
          ${clients.antigravity.gatewayConfig.source} > /dev/null
        jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
          '. == {mcp: {gateway: {type: "remote", url: $expected}}}' \
          ${clients.opencode.gatewayConfig.source} > /dev/null
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
        remarshal -if toml -of json ${artifactSource "agents/codex/system"} > codex-system.json
        codex_mcp_matches ${lib.escapeShellArg gatewayUrl} < codex-system.json > /dev/null
        jq --exit-status \
          --arg cacheRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.cache/dotfiles-wsl"} \
          --arg stateRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.local/state/dotfiles-wsl"} '
          .sandbox_workspace_write.writable_roots == [$cacheRoot, $stateRoot]
        ' codex-system.json > /dev/null
        remarshal -if toml -of json ${artifactSource "agents/codex/project"} > codex-project.json
        jq --exit-status \
          --arg cacheRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.cache/dotfiles-wsl"} \
          --arg stateRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.local/state/dotfiles-wsl"} \
          --arg gitRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.dotfilesDir}/.git"} '
          .sandbox_workspace_write.writable_roots == [$cacheRoot, $stateRoot, $gitRoot]
        ' codex-project.json > /dev/null
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
        remarshal -if toml -of json ${variantClients.codex.managedFiles.system.source} \
          > codex-system-variant.json
        codex_mcp_matches ${lib.escapeShellArg variantGatewayUrl} \
          < codex-system-variant.json > /dev/null

        fixture=$PWD/seed-fixture
        mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
        printf '%s\n' keep-regular > "$fixture/home/.claude/settings.json"
        ln -s nowhere "$fixture/home/.codex/config.toml"
        ${fixtureSeedActivation}
        grep -Fxq keep-regular "$fixture/home/.claude/settings.json"
        test -L "$fixture/home/.codex/config.toml"
        test "$(readlink "$fixture/home/.codex/config.toml")" = nowhere

        rm "$fixture/home/.claude/settings.json" "$fixture/home/.codex/config.toml"
        mkdir "$fixture/home/.claude/settings.json"
        ${fixtureSeedActivation}
        test -d "$fixture/home/.claude/settings.json"
        test -s "$fixture/home/.codex/config.toml"

        rmdir "$fixture/home/.claude/settings.json"
        ${fixtureSeedActivation}
        test -s "$fixture/home/.claude/settings.json"

        test ! -e ${self}/clis
        legacy_root=clis
        legacy_role=cli
        legacy_option=m
        legacy_option+='y\.'
        legacy_pattern="$legacy_option''${legacy_root}|dotfiles-install-''${legacy_root}|dotfiles-''${legacy_role}-autoupdate|''${legacy_root}/assets|''${legacy_root}/(antigravity|claude|codex|opencode)"
        if rg -n "$legacy_pattern" ${self}; then
          echo "legacy clis path or runtime identity remains" >&2
          exit 1
        fi
        if rg -n "$legacy_option"'agents|agents/(antigravity|claude|codex|opencode)' ${self}/containers; then
          echo "container backend declares or depends on agent configuration" >&2
          exit 1
        fi

        touch $out
      '';

  agent-definition-rendering =
    assert clients.claude.definitions == hostConfig.dotfiles.agents.shared.definitions;
    assert clients.antigravity.definitions == { };
    assert sharedDefinitionSources != [ ];
    assert codexDefinitionSources != [ ];
    assert opencodeDefinitionSources != [ ];
    assert lib.all (source: lib.hasPrefix builtins.storeDir (toString source)) (
      builtins.attrValues hostConfig.dotfiles.agents.shared.skills
    );
    pkgs.runCommandLocal "check-agent-definition-rendering"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.glibc.bin
          pkgs.gnugrep
          pkgs.jq
          pkgs.remarshal
          pkgs.yq
        ];
        rulesSource = hostConfig.dotfiles.agents.shared.rules;
        sharedSources = sharedDefinitionSources;
        claudeSources = claudeDefinitionSources;
        codexSources = codexDefinitionSources;
        opencodeSources = opencodeDefinitionSources;
      }
      ''
        set -euo pipefail

        test -s "$rulesSource"
        iconv -f UTF-8 -t UTF-8 "$rulesSource" > /dev/null
        grep -Eq '^#{1,6}[[:space:]]+[^[:space:]]' "$rulesSource"

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
        done
        for source in $opencodeSources; do
          check_frontmatter "$source"
        done
        for source in $codexSources; do
          remarshal -if toml -of json "$source" > definition.json
          jq --exit-status '.developer_instructions | length > 0' definition.json > /dev/null
        done

        paste \
          <(printf '%s\n' $sharedSources) \
          <(printf '%s\n' $claudeSources) \
          | while IFS=$'\t' read -r shared claude; do
              cmp "$shared" "$claude"
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
        jq --sort-keys '.lsp | keys' ${artifactSource "agents/opencode/config"} > opencode-names.json
        printf '%s' ${lib.escapeShellArg (builtins.toJSON (builtins.attrNames roster))} \
          | jq --sort-keys '.' > expected-names.json
        diff --unified expected-names.json claude-names.json
        diff --unified expected-names.json opencode-names.json

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
            .lsp["${name}"].command == $command and
            (.lsp["${name}"].extensions | sort) == ($extensions | sort) and
            (.lsp["${name}"].initialization // {}) == $options
          ' ${artifactSource "agents/opencode/config"} > /dev/null
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

  agent-runtime-contract =
    assert builtins.head homeConfig.home.sessionPath == "$HOME/${wrapperDirectory}";
    assert lib.elem "$HOME/.local/bin" homeConfig.home.sessionPath;
    assert
      runtimeClientNames == [
        "claude"
        "codex"
        "opencode"
      ];
    assert builtins.all (
      name:
      let
        target = "${wrapperDirectory}/${clients.${name}.binary}";
      in
      builtins.hasAttr target homeConfig.home.file && homeConfig.home.file.${target}.executable
    ) runtimeClientNames;
    assert !(builtins.hasAttr "${wrapperDirectory}/${clients.antigravity.binary}" homeConfig.home.file);
    pkgs.runCommandLocal "check-agent-runtime-contract" { } ''
      set -euo pipefail
      ${lib.concatMapStrings (name: ''
        wrapper=${homeConfig.home.file."${wrapperDirectory}/${clients.${name}.binary}".source}
        grep -Fq ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.local/bin/${clients.${name}.binary}"} "$wrapper"
        grep -Fq ${lib.escapeShellArg (lib.getExe runtime.launcher)} "$wrapper"
      '') runtimeClientNames}
      touch $out
    '';

  agent-runtime-behavior =
    pkgs.runCommandLocal "check-agent-runtime-behavior"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.git
          pkgs.gnused
          pkgs.jq
        ];
        LAUNCHER = lib.getExe runtime.launcher;
        AGENT_SHIM_DIR = runtime.agentShims;
        GIT_SHIM_DIR = fixtureAgentShims;
      }
      ''
        bash ${./runtime/tests/launcher.sh}
        bash ${./runtime/tests/git-shim.sh}
        touch $out
      '';

  agent-nix-build-shims =
    pkgs.runCommandLocal "check-agent-nix-build-shims"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
        ];
        SHIM_DIR = fixtureNixBuildShims;
      }
      ''
        bash ${./runtime/tests/nix-build-shims.sh}
        touch $out
      '';

  agent-project-cache-gc =
    assert lib.count (package: package == runtime.gc) hostConfig.environment.systemPackages == 1;
    assert
      hostConfig.systemd.services.dotfiles-agent-project-cache-gc.serviceConfig.ExecStart
      == lib.getExe runtime.gc;
    assert
      hostConfig.systemd.services.dotfiles-agent-project-cache-gc.serviceConfig.User
      == hostConfig.dotfiles.host.username;
    assert hostConfig.systemd.services.dotfiles-agent-project-cache-gc.serviceConfig.Type == "oneshot";
    assert hostConfig.systemd.timers.dotfiles-agent-project-cache-gc.timerConfig.OnCalendar == "daily";
    assert hostConfig.systemd.timers.dotfiles-agent-project-cache-gc.timerConfig.Persistent;
    pkgs.runCommandLocal "check-agent-project-cache-gc"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
        GC = lib.getExe runtime.gc;
      }
      ''
        bash ${./runtime/tests/project-cache-gc.sh}
        touch $out
      '';

  agent-verification-cache =
    assert lib.count (package: package == runtime.verify) hostConfig.environment.systemPackages == 1;
    pkgs.runCommandLocal "check-agent-verification-cache"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.git
          pkgs.gnused
        ];
        VERIFY = lib.getExe runtime.verify;
      }
      ''
        bash ${./runtime/tests/verify.sh}
        touch $out
      '';
}
