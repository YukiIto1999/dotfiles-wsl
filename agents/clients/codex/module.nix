{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles;
  projectMemoryEnabled = builtins.elem "project-memory" cfg.capabilities.resolved;
  codexModel = "gpt-6-sol";
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
  codexSystemBaseTemplate = pkgs.replaceVars ./assets/config-system.toml {
    inherit codexModel;
    homeDir = cfg.workstation.homeDir;
  };
  codexSystemBaseWithoutProjectMemory =
    pkgs.runCommandLocal "codex-system-base-without-project-memory.toml"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.remarshal
        ];
      }
      ''
        set -euo pipefail
        remarshal -if toml -of json ${codexSystemBaseTemplate} \
          | jq 'del(.hooks)' \
          | remarshal -if json -of toml > "$out"
      '';
  codexSystemBase =
    if projectMemoryEnabled then codexSystemBaseTemplate else codexSystemBaseWithoutProjectMemory;
  # subagent file は symlink だと O_NOFOLLOW で開けないため、store の実体を直接指す
  codexAgentsConfig = (pkgs.formats.toml { }).generate "codex-agents.toml" {
    agents = {
      default_subagent_model = codexModel;
      default_subagent_reasoning_effort = "xhigh";
    }
    // lib.mapAttrs (_: source: { config_file = toString source; }) codexSubagents;
  };
  codexSystemConfig =
    pkgs.runCommandLocal "codex-system-config.toml"
      {
        nativeBuildInputs = [ pkgs.gnugrep ];
      }
      ''
        set -euo pipefail
        cat ${codexSystemBase} ${codexAgentsConfig} ${codexRuntimeConfig} ${codexGatewayConfig} > "$out"
        if grep -qE '@[a-zA-Z][a-zA-Z0-9]*@' "$out"; then
          echo "Codex system config has an unresolved template marker" >&2
          exit 1
        fi
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

  buildSubagent =
    name: srcPath:
    pkgs.runCommand "${name}.toml"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnused
          pkgs.remarshal
          pkgs.yq
        ];
      }
      ''
        test "$(head -n 1 ${srcPath})" = '---'
        closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' ${srcPath})
        test -n "$closing"
        sed -n "2,$((closing - 1))p" ${srcPath} > frontmatter.yaml
        tail -n "+$((closing + 1))" ${srcPath} > body.md

        # frontmatter から codex agent schema への変換
        yq -y '
          del(.tools)
          | if has("effort") then .model_reasoning_effort = .effort | del(.effort) else . end
        ' frontmatter.yaml | remarshal -if yaml -of toml > "$out"
        {
          printf 'model = "${codexModel}"\n'
          printf 'developer_instructions = """\n'
          cat body.md
          printf '\n"""\n'
        } >> "$out"
      '';
  codexSubagents = lib.mapAttrs buildSubagent cfg.agents.shared.subagents;
in
{
  dotfiles.agents.registry.codex = {
    binary = "codex";
    supply.package = "codex";
    runtime.managed = { };
    rules.file.destination = ".codex/AGENTS.md";
    skillsDestination = ".codex/skills";
    subagents.declared = {
      sources = codexSubagents;
      skillProjection = "dynamic";
    };
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
      user = {
        source = codexUserSeed;
        format = "toml";
        deployment = "seed";
        destination = ".codex/config.toml";
        seedMigrationCommand = migrateCodexConfig;
      };
    };
    lsp.unsupported = { };
    telemetry.unsupported = { };
    projectMemory =
      if projectMemoryEnabled then { hooks.managedFile = "system"; } else { unsupported = { }; };
  };

  # codex の workspace-write sandbox が PATH 上に要求する bubblewrap
  environment.systemPackages = lib.optionals (builtins.elem "codex" cfg.agents.enabled) [
    pkgs.bubblewrap
  ];
}
