{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles;
  codexRuntime = config.dotfiles.capabilities.agent-session.codex.runtime;

  codexModel = "gpt-5.6-sol";
  dotfilesHomeRelative = lib.removePrefix "${cfg.workstation.homeDir}/" cfg.workstation.dotfilesDir;
  dotfilesPathComponents = lib.splitString "/" dotfilesHomeRelative;
  dotfilesDirIsBelowHome =
    lib.hasPrefix "${cfg.workstation.homeDir}/" cfg.workstation.dotfilesDir
    && lib.all (
      component: component != "" && component != "." && component != ".."
    ) dotfilesPathComponents;
  codexProjectHomePath = "${dotfilesHomeRelative}/.codex/config.toml";
  codexProjectConfig = (pkgs.formats.toml { }).generate "codex-project-config.toml" {
    permissions.dev.filesystem."${cfg.workstation.dotfilesDir}/.git" = "write";
  };
  agentRuntimeWritableFilesystem = {
    "${cfg.workstation.homeDir}/.cache/dotfiles-wsl" = "write";
    "${cfg.workstation.homeDir}/.local/state/dotfiles-wsl" = "write";
  };
  codexRuntimeConfig = (pkgs.formats.toml { }).generate "codex-runtime.toml" {
    permissions.dev.filesystem = agentRuntimeWritableFilesystem;
  };
  codexGatewayConfig = (pkgs.formats.toml { }).generate "codex-gateway.toml" {
    mcp_servers.gateway.url = config.dotfiles.platform.mcp.gateway.url;
  };
  codexSystemBase = pkgs.replaceVars ./assets/config-system.toml {
    inherit codexModel;
    homeDir = cfg.workstation.homeDir;
  };
  # role file は symlink だと O_NOFOLLOW で開けないため、store の実体を直接指す
  codexAgentsConfig = (pkgs.formats.toml { }).generate "codex-agents.toml" {
    agents = {
      default_subagent_model = codexModel;
      default_subagent_reasoning_effort = "xhigh";
    }
    // lib.mapAttrs (_: source: { config_file = toString source; }) codexAgentDefinitions;
  };
  codexSystemConfig = pkgs.runCommandLocal "codex-system-config.toml" { } ''
    cat ${codexSystemBase} ${codexAgentsConfig} ${codexRuntimeConfig} ${codexGatewayConfig} > "$out"
  '';
  codexUserSeed = pkgs.replaceVars ./assets/config.toml {
    inherit codexModel;
    homeDir = cfg.workstation.homeDir;
  };
  migrateCodexConfig = pkgs.writeShellApplication {
    name = "dotfiles-migrate-codex-config";
    text =
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
          "${pkgs.coreutils}/bin/mktemp"
          "${pkgs.coreutils}/bin/mv"
          (lib.getExe pkgs.remarshal)
          "${pkgs.coreutils}/bin/rm"
          "${pkgs.coreutils}/bin/stat"
        ]
        (builtins.readFile ./impl/migrate-config.sh);
  };

  splitFrontmatter =
    src:
    let
      parts = lib.splitString "\n---\n" (builtins.readFile src);
    in
    {
      frontmatter = lib.removePrefix "---\n" (builtins.head parts);
      body = lib.concatStringsSep "\n---\n" (builtins.tail parts);
    };

  buildAgent =
    name: srcPath:
    let
      fm = splitFrontmatter srcPath;
    in
    pkgs.runCommand "${name}.toml"
      {
        nativeBuildInputs = [
          pkgs.remarshal
          pkgs.yq
        ];
        inherit (fm) frontmatter body;
      }
      ''
        # frontmatter から codex agent schema への変換
        yq -y '
          del(.tools)
          | if has("effort") then .model_reasoning_effort = .effort | del(.effort) else . end
        ' <<<"$frontmatter" | remarshal -if yaml -of toml > "$out"
        {
          printf 'model = "${codexModel}"\n'
          printf 'developer_instructions = """\n'
          printf '%s\n' "$body"
          printf '"""\n'
        } >> "$out"
      '';
  codexAgentDefinitions = lib.mapAttrs buildAgent cfg.agents.shared.definitions;
in
{
  dotfiles.agents.clients.codex = {
    inherit (codexRuntime) binary;
    runtimeWrapperMode = "managed";
    rulesDestination = ".codex/AGENTS.md";
    skillsDestination = ".codex/skills";
    definitionMode = "declared";
    definitionFormat = "toml";
    definitions = codexAgentDefinitions;
    gatewayConfig = {
      source = codexGatewayConfig;
      format = "toml";
      managedFile = "system";
    };
    managedFiles = {
      system = {
        source = codexSystemConfig;
        format = "toml";
        deployment = "system";
        destination = "codex/config.toml";
      };
      project = {
        source = codexProjectConfig;
        format = "toml";
        deployment = "home";
        destination = codexProjectHomePath;
      };
      user = {
        source = codexUserSeed;
        format = "toml";
        deployment = "seed";
        destination = ".codex/config.toml";
        seedMigrationCommand = migrateCodexConfig;
      };
    };
    capabilityManagedFiles.agentmemory = "system";
    lspMode = "unsupported";
    telemetryMode = "unsupported";
    agentmemoryMode = "hooks";
    skillProjectionMode = "dynamic";
    inherit (codexRuntime) install;
  };

  # codex の workspace-write sandbox が PATH 上に要求する bubblewrap
  environment.systemPackages = [ pkgs.bubblewrap ];

  assertions = [
    {
      assertion = dotfilesDirIsBelowHome;
      message = "dotfiles.workstation.dotfilesDir must be a normalized path below dotfiles.workstation.homeDir for Codex project config deployment";
    }
  ];
}
