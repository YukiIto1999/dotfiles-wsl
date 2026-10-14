{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  projectMemoryEnabled = builtins.elem "project-memory" cfg.capabilities.resolved;
  managedMcp = pkgs.replaceVars ./assets/managed-mcp.json {
    gatewayUrl = config.dotfiles.platform.mcp.gateway.url;
  };
  requiredSkillsFor =
    name:
    map (route: route.skill) (
      builtins.filter (
        route: route.subagent == name && route.activation == "required"
      ) cfg.agents.shared.routing.subagentSkills
    );

  userSettingsSeed = ./assets/settings.json;

  # settings.json に lspServers は無く、登録経路は plugin だけである
  lspJson = (pkgs.formats.json { }).generate "claude-lsp.json" (
    lib.mapAttrs (
      _: server:
      {
        inherit (server) command;
        extensionToLanguage = server.extensions;
      }
      // lib.optionalAttrs (server.args != [ ]) { inherit (server) args; }
      // lib.optionalAttrs (server.initializationOptions != { }) {
        inherit (server) initializationOptions;
      }
    ) cfg.toolchain.lsp
  );

  # directory source の marketplace は git を持たないので version を明示する。
  # 内容が変われば store hash が変わり、Claude が更新として扱う
  lspVersion = builtins.head (lib.splitString "-" (builtins.baseNameOf lspJson));

  lspMarketplace = pkgs.runCommandLocal "claude-lsp-marketplace" { } ''
    mkdir -p $out/.claude-plugin $out/lsp/.claude-plugin
    cp ${
      (pkgs.formats.json { }).generate "marketplace.json" {
        name = "dotfiles";
        owner.name = cfg.workstation.username;
        plugins = [
          {
            name = "lsp";
            source = "./lsp";
            description = "dotfiles が宣言する language server";
            version = lspVersion;
          }
        ];
      }
    } $out/.claude-plugin/marketplace.json
    cp ${
      (pkgs.formats.json { }).generate "plugin.json" {
        name = "lsp";
        description = "dotfiles が宣言する language server";
        version = lspVersion;
      }
    } $out/lsp/.claude-plugin/plugin.json
    cp ${lspJson} $out/lsp/.lsp.json
  '';

  buildSubagent =
    name: srcPath:
    pkgs.runCommand "claude-agent-${name}.md"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnused
          pkgs.yq
        ];
        requiredSkills = builtins.toJSON (requiredSkillsFor name);
      }
      ''
        test "$(head -n 1 ${srcPath})" = '---'
        closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' ${srcPath})
        test -n "$closing"
        sed -n "2,$((closing - 1))p" ${srcPath} > frontmatter.yaml
        rendered=$(yq -y --argjson requiredSkills "$requiredSkills" '
          .tools = ((.tools + ["Skill", "mcp__gateway"]) | unique)
          | if ($requiredSkills | length) > 0
            then .skills = $requiredSkills
            else del(.skills)
            end
        ' frontmatter.yaml)
        {
          printf '%s\n' '---'
          printf '%s\n' "$rendered"
          printf '%s\n' '---'
          tail -n "+$((closing + 1))" ${srcPath}
        } > "$out"
      '';

  managedSettingsBase = pkgs.replaceVars ./assets/managed-settings.json {
    lspMarketplacePath = "${lspMarketplace}";
    telemetryEndpoint = cfg.telemetry.endpoint;
    telemetryProtocol = cfg.telemetry.protocol;
  };
  managedSettings =
    pkgs.runCommandLocal "claude-managed-settings.json" { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        jq --rawfile policy ${cfg.agents.shared.rules} \
          --argjson projectMemoryEnabled ${lib.boolToString projectMemoryEnabled} \
          --argjson telemetryEnabled ${lib.boolToString cfg.telemetry.enable} '
          .claudeMd = $policy
          | if $telemetryEnabled then . else
              .env.CLAUDE_CODE_ENABLE_TELEMETRY = "0"
              | .env.OTEL_METRICS_EXPORTER = "none"
              | .env.OTEL_LOGS_EXPORTER = "none"
            end
          | if $projectMemoryEnabled then . else
              .hooks |= (
                map_values(
                  map(.hooks |= map(select(.command | test("dotfiles-memory hook --harness") | not)))
                  | map(select(.hooks | length > 0))
                )
                | map_values(select(length > 0))
              )
            end
        ' ${managedSettingsBase} > "$out"
      '';
in
{
  dotfiles.agents.registry.claude = {
    binary = "claude";
    supply.package = "claude-code";
    runtime.managed = { };
    rules.embedded = { };
    skillsDestination = ".claude/skills";
    subagents.rendered = {
      destination = ".claude/agents";
      sources = lib.mapAttrs buildSubagent cfg.agents.shared.subagents;
      skillProjection = "preload";
    };
    gatewayConfig = {
      source = managedMcp;
      format = "json";
      managedFile = "managed-mcp";
    };
    managedFiles = {
      managed-settings = {
        source = managedSettings;
        format = "json";
        deployment = "system";
        destination = "claude-code/managed-settings.json";
      };
      managed-mcp = {
        source = managedMcp;
        format = "json";
        deployment = "system";
        destination = "claude-code/managed-mcp.json";
      };
      user-settings = {
        source = userSettingsSeed;
        format = "json";
        deployment = "seed";
        destination = ".claude/settings.json";
      };
    };
    lsp.supported.managedFile = "managed-settings";
    telemetry.supported.managedFile = "managed-settings";
    projectMemory =
      if projectMemoryEnabled then
        { hooks.managedFile = "managed-settings"; }
      else
        { unsupported = { }; };
  };
}
