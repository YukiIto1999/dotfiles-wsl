{
  config,
  lib,
  pkgs,
  seedConfig,
  ...
}:

let
  cfg = config.my;
  managedMcp = pkgs.replaceVars ./assets/managed-mcp.json {
    gatewayUrl = cfg.contract.mcp.endpoints.default.url;
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
  ) cfg.lsp;

  lspJson = (pkgs.formats.json { }).generate "claude-lsp.json" lspServers;

  # directory source の marketplace は git を持たないので version を明示する。
  # 内容が変われば store hash が変わり、Claude が更新として扱う
  lspVersion = builtins.head (lib.splitString "-" (builtins.baseNameOf lspJson));

  lspMarketplace = pkgs.runCommandLocal "claude-lsp-marketplace" { } ''
    mkdir -p $out/.claude-plugin $out/lsp/.claude-plugin
    cp ${
      (pkgs.formats.json { }).generate "marketplace.json" {
        name = "dotfiles";
        owner.name = cfg.username;
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
    telemetryEndpoint = cfg.contract.telemetry.endpoint;
    telemetryProtocol = cfg.contract.telemetry.protocol;
  };
in
{
  my.clis.claude = {
    binary = "claude";
    rulesFile = ".claude/CLAUDE.md";
    skillsDir = ".claude/skills";
    agentsDir = ".claude/agents";
    buildAgent = _: srcPath: srcPath;
    gatewayFile = null;
    install = {
      kind = "installer-script";
      scriptUrl = "https://claude.ai/install.sh";
    };
  };

  my.configArtifacts = {
    "clis/claude/managed-settings" = {
      format = "json";
      source = managedSettings;
    };
    "clis/claude/lsp" = {
      format = "json";
      source = lspJson;
    };
    "clis/claude/managed-mcp" = {
      format = "json";
      source = managedMcp;
    };
    "clis/claude/user-settings-seed" = {
      format = "json";
      source = userSettingsSeed;
    };
  };

  environment.etc."claude-code/managed-settings.json".source = managedSettings;

  # nix 所有 config パターンで gateway 登録を宣言的化
  environment.etc."claude-code/managed-mcp.json".source = managedMcp;

  my.doctor.managedFiles = {
    claude-settings = {
      path = "/etc/claude-code/managed-settings.json";
      source = config.environment.etc."claude-code/managed-settings.json".source;
    };
    claude-mcp = {
      path = "/etc/claude-code/managed-mcp.json";
      source = config.environment.etc."claude-code/managed-mcp.json".source;
    };
  };

  home-manager.users.${cfg.username} =
    { lib, ... }:
    {
      home.activation.seedClaudeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        seedConfig ".claude/settings.json" userSettingsSeed
      );
    };
}
