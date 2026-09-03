{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  lspProjection = import ../../impl/lsp.nix { inherit lib; };
  managedMcp = pkgs.replaceVars ./assets/managed-mcp.json {
    gatewayUrl = config.dotfiles.platform.mcp.gateway.url;
  };
  requiredSkillsFor =
    name:
    map (route: route.skill) (
      builtins.filter (
        route: route.agent == name && route.activation == "required"
      ) cfg.agents.shared.routing.agentSkills
    );

  userSettingsSeed = ./assets/settings.json;

  # settings.json に lspServers は無く、登録経路は plugin だけである
  lspJson = (pkgs.formats.json { }).generate "claude-lsp.json" (
    lspProjection.claude cfg.toolchain.lsp
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

  buildAgent =
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

  managedSettings = pkgs.replaceVars ./assets/managed-settings.json {
    lspMarketplacePath = "${lspMarketplace}";
    telemetryEndpoint = cfg.telemetry.endpoint;
    telemetryProtocol = cfg.telemetry.protocol;
  };
in
{
  dotfiles.agents.clients.claude = {
    binary = "claude";
    runtimeWrapperMode = "managed";
    rulesDestination = ".claude/CLAUDE.md";
    skillsDestination = ".claude/skills";
    definitionMode = "rendered";
    definitionsDestination = ".claude/agents";
    definitionFormat = "frontmatter-markdown";
    definitions = lib.mapAttrs buildAgent cfg.agents.shared.definitions;
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
    capabilityManagedFiles = {
      lsp = "managed-settings";
      telemetry = "managed-settings";
      agentmemory = "managed-settings";
    };
    lspMode = "supported";
    telemetryMode = "supported";
    agentmemoryMode = "hooks";
    skillProjectionMode = "preload";
    install = {
      kind = "installer-script";
      updateOwner = "upstream-installer";
      layout = "upstream-managed";
      scriptUrl = "https://claude.ai/install.sh";
    };
  };
}
