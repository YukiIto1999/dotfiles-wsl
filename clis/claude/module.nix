{
  config,
  pkgs,
  seedConfig,
  ...
}:

let
  cfg = config.my;
  managedMcp = pkgs.replaceVars ./assets/managed-mcp.json {
    inherit (cfg) gatewayUrl;
  };
  userSettingsSeed = ./assets/settings.json;
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
      source = ./assets/managed-settings.json;
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

  environment.etc."claude-code/managed-settings.json".source = ./assets/managed-settings.json;

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
