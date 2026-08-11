{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles;

  codexModel = "gpt-5.6-sol";
  dotfilesHomeRelative = lib.removePrefix "${cfg.host.homeDir}/" cfg.host.dotfilesDir;
  dotfilesPathComponents = lib.splitString "/" dotfilesHomeRelative;
  dotfilesDirIsBelowHome =
    lib.hasPrefix "${cfg.host.homeDir}/" cfg.host.dotfilesDir
    && lib.all (
      component: component != "" && component != "." && component != ".."
    ) dotfilesPathComponents;
  codexProjectHomePath = "${dotfilesHomeRelative}/.codex/config.toml";
  codexProjectConfig = (pkgs.formats.toml { }).generate "codex-project-config.toml" {
    permissions.dev.filesystem."${cfg.host.dotfilesDir}/.git" = "write";
  };
  agentRuntimeWritableFilesystem = {
    "${cfg.host.homeDir}/.cache/dotfiles-wsl" = "write";
    "${cfg.host.homeDir}/.local/state/dotfiles-wsl" = "write";
  };
  codexRuntimeConfig = (pkgs.formats.toml { }).generate "codex-runtime.toml" {
    permissions = {
      dev.filesystem = agentRuntimeWritableFilesystem;
      agent-read-only = {
        extends = ":read-only";
        filesystem = agentRuntimeWritableFilesystem;
      };
    };
  };
  codexGatewayConfig = (pkgs.formats.toml { }).generate "codex-gateway.toml" {
    mcp_servers.gateway.url = config.dotfiles.mcp.gateway.url;
  };
  codexSystemBase = pkgs.replaceVars ./assets/config-system.toml { inherit codexModel; };
  codexSystemConfig = pkgs.runCommandLocal "codex-system-config.toml" { } ''
    cat ${codexSystemBase} ${codexRuntimeConfig} ${codexGatewayConfig} > "$out"
  '';
  codexUserSeed = pkgs.replaceVars ./assets/config.toml {
    inherit codexModel;
    homeDir = cfg.host.homeDir;
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
          ((.tools // []) | any(. == "Edit" or . == "Write") | not) as $readOnly
          | del(.tools)
          | if has("effort") then .model_reasoning_effort = .effort | del(.effort) else . end
          | if $readOnly then .default_permissions = "agent-read-only" else . end
        ' <<<"$frontmatter" | remarshal -if yaml -of toml > "$out"
        {
          printf 'model = "${codexModel}"\n'
          printf 'developer_instructions = """\n'
          printf '%s\n' "$body"
          printf '"""\n'
        } >> "$out"
      '';
in
{
  dotfiles.agents.clients.codex = {
    binary = "codex";
    rulesDestination = ".codex/AGENTS.md";
    skillsDestination = ".codex/skills";
    definitionMode = "rendered";
    definitionsDestination = ".codex/agents";
    definitionFormat = "toml";
    definitions = lib.mapAttrs buildAgent cfg.agents.shared.definitions;
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
    install = {
      kind = "github-release";
      updateOwner = "dotfiles";
      layout = "single-binary";
      repo = "openai/codex";
      releaseByArch = {
        x86_64 = {
          asset = "codex-x86_64-unknown-linux-musl.tar.gz";
          entrypoint = "codex-x86_64-unknown-linux-musl";
        };
        aarch64 = {
          asset = "codex-aarch64-unknown-linux-musl.tar.gz";
          entrypoint = "codex-aarch64-unknown-linux-musl";
        };
      };
      requiredPaths = { };
    };
  };

  # codex の workspace-write sandbox が PATH 上に要求する bubblewrap
  environment.systemPackages = [ pkgs.bubblewrap ];

  assertions = [
    {
      assertion = dotfilesDirIsBelowHome;
      message = "dotfiles.host.dotfilesDir must be a normalized path below dotfiles.host.homeDir for Codex project config deployment";
    }
  ];
}
