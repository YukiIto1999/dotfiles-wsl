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
  expected = builtins.fromJSON (builtins.readFile ../fixtures/client-contract.json);
  agentConfig = hostConfig.dotfiles.agents;
  inherit (agentConfig) clients;
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
  atomicPublish = import ../impl/atomic-publish.nix { inherit pkgs; };
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
      (builtins.readFile ../codex/impl/migrate-config.sh)
  );

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

  sharedDefinitionSources = builtins.attrValues hostConfig.dotfiles.agents.shared.definitions;
  securityDefinitionSource = hostConfig.dotfiles.agents.shared.definitions.security;
  claudeDefinitionSources = builtins.attrValues clients.claude.definitions;
  codexDefinitionSources = builtins.attrValues clients.codex.definitions;
  opencodeDefinitionSources = builtins.attrValues clients.opencode.definitions;
in
{
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
      && lib.elem hostConfig.dotfiles.agents.agentmemory.hooks definition.value
    ) hostOptions.environment.systemPackages.definitionsWithLocations;
    assert
      clients.opencode.managedFiles.agentmemory-plugin.source
      == hostConfig.dotfiles.agents.agentmemory.opencodePlugin;
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
        codexDefinitionSources = lib.concatStringsSep " " (map toString codexDefinitionSources);
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

        grep -Fq 'dotfiles-doctor` は `dotfiles.observations` の全登録を観測し' ${self}/agents/shared/AGENTS.md
        grep -Fq 'skill を含む managed artifact と current source の不一致も検査する' ${self}/agents/shared/AGENTS.md
        grep -Fq 'skill の動作や意味、subagents 表と実際の agent 機能との整合は observation に登録しておらず、自動検査しない' ${self}/agents/shared/AGENTS.md
        grep -Fq 'seed は runtime drift の対象にしない' ${self}/docs/architecture/ai-tooling.md
        grep -Fq 'managed file は artifact owner が observation を登録し、doctor が current source との不一致を検査する' ${self}/docs/architecture/ai-tooling.md

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
          .permissions.dev.filesystem == {($cacheRoot): "write", ($stateRoot): "write"} and
          .permissions["agent-read-only"] == {
            extends: ":read-only",
            filesystem: {($cacheRoot): "write", ($stateRoot): "write"}
          } and
          (has("sandbox_mode") | not) and
          (has("sandbox_workspace_write") | not)
        ' codex-system.json > /dev/null
        remarshal -if toml -of json ${artifactSource "agents/codex/project"} > codex-project.json
        jq --exit-status \
          --arg cacheRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.cache/dotfiles-wsl"} \
          --arg stateRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.local/state/dotfiles-wsl"} \
          --arg gitRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.dotfilesDir}/.git"} '
          .permissions.dev.filesystem == {($gitRoot): "write"} and
          (has("sandbox_mode") | not) and
          (has("sandbox_workspace_write") | not)
        ' codex-project.json > /dev/null
        remarshal -if toml -of json \
          ${clients.codex.managedFiles.user.source} > codex-user-seed.json
        grep -Fq '"@homeDir@/workspace"' ${self}/agents/codex/assets/config.toml
        grep -Fq '"@homeDir@/projects"' ${self}/agents/codex/assets/config.toml
        if rg -n '/home/nixos/(workspace|projects)' ${self}/agents/codex/assets/config.toml; then
          echo "Codex seed hard-codes the host home directory" >&2
          exit 1
        fi
        jq --exit-status \
          --arg homeDir ${lib.escapeShellArg hostConfig.dotfiles.host.homeDir} '
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
        for definition in $codexDefinitionSources; do
          remarshal -if toml -of json "$definition" > codex-definition.json
          jq --exit-status '
            (has("sandbox_mode") | not) and
            (has("sandbox_workspace_write") | not) and
            if (.name | IN("architect", "explorer", "planner", "reviewer", "security"))
            then
              .default_permissions == "agent-read-only" and
              (has("permissions") | not)
            else
              (has("default_permissions") | not) and
              (has("permissions") | not)
            end
          ' codex-definition.json > /dev/null
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
        inherit securityDefinitionSource;
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

        extract_definition_section() {
          local heading=$1 source=$2
          awk -v heading="$heading" '
            $0 == heading { inside = 1; next }
            inside && /^## / { exit }
            inside { print }
          ' "$source"
        }
        extract_definition_section '## Scan' "$securityDefinitionSource" > security-scan-section.md
        for phase in security-scan threat-model finding-discovery validation attack-path-analysis; do
          grep -Fq "$phase" security-scan-section.md
        done
        grep -Fq 'security-scan → threat-model → finding-discovery → validation → attack-path-analysis → 最終 report' \
          security-scan-section.md
        if grep -Fq 'fix-finding' security-scan-section.md; then
          echo "security scan phase includes finding repair" >&2
          exit 1
        fi
        extract_definition_section '## Finding fix handoff' "$securityDefinitionSource" \
          > security-fix-handoff-section.md
        grep -Fq 'fix-finding' security-fix-handoff-section.md
        grep -Fq '実装agent' security-fix-handoff-section.md
        grep -Fq '修正を実装しない' security-fix-handoff-section.md
        grep -Fq '$HOME/.local/state/dotfiles-wsl/security-scans/<repo_name>' \
          "$securityDefinitionSource"
        grep -Fq '再現用の使い捨てdataだけを割り当て済み`TMPDIR`へ置き' \
          "$securityDefinitionSource"
        grep -Fq 'plugin既定の`/tmp/codex-security-scans/<repo_name>`は使わない' \
          "$securityDefinitionSource"
        security_frontmatter_end=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' \
          "$securityDefinitionSource")
        sed -n "2,$((security_frontmatter_end - 1))p" "$securityDefinitionSource" \
          > security-frontmatter.yaml
        yq --exit-status '.tools == ["Read", "Bash", "Grep", "Glob"]' \
          security-frontmatter.yaml > /dev/null

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
}
