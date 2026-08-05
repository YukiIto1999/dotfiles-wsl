{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  managedMcp = pkgs.replaceVars ./assets/managed-mcp.json {
    gatewayUrl = config.dotfiles.mcp.gateway.url;
  };
  userSettingsSeed = ./assets/settings.json;

  # settings.json に lspServers は無く、登録経路は plugin だけである
  lspServers = lib.mapAttrs (
    _: server:
    {
      inherit (server) command;
      extensionToLanguage = server.extensions;
    }
    // lib.optionalAttrs (server.args != [ ]) { inherit (server) args; }
    // lib.optionalAttrs (server.initializationOptions != { }) {
      inherit (server) initializationOptions;
    }
  ) cfg.toolchain.lsp;

  lspJson = (pkgs.formats.json { }).generate "claude-lsp.json" lspServers;

  # directory source の marketplace は git を持たないので version を明示する。
  # 内容が変われば store hash が変わり、Claude が更新として扱う
  lspVersion = builtins.head (lib.splitString "-" (builtins.baseNameOf lspJson));

  lspMarketplace = pkgs.runCommandLocal "claude-lsp-marketplace" { } ''
    mkdir -p $out/.claude-plugin $out/lsp/.claude-plugin
    cp ${
      (pkgs.formats.json { }).generate "marketplace.json" {
        name = "dotfiles";
        owner.name = cfg.host.username;
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

  managedSettings = pkgs.replaceVars ./assets/managed-settings.json {
    lspMarketplacePath = "${lspMarketplace}";
    telemetryEndpoint = cfg.telemetry.endpoint;
    telemetryProtocol = cfg.telemetry.protocol;
  };
in
{
  dotfiles.agents.clients.claude = {
    binary = "claude";
    rulesDestination = ".claude/CLAUDE.md";
    skillsDestination = ".claude/skills";
    definitionMode = "native";
    definitionsDestination = ".claude/agents";
    definitionFormat = null;
    definitions = cfg.agents.shared.definitions;
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
    install = {
      kind = "installer-script";
      scriptUrl = "https://claude.ai/install.sh";
    };
  };

  dotfiles.artifacts = {
    "agents/claude/lsp" = {
      format = "json";
      source = lspJson;
    };
  };
}
