{
  config,
  pkgs,
  seedConfig,
  ...
}:

let
  cfg = config.my;
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

  environment.etc."claude-code/managed-settings.json".source = ./managed-settings.json;

  # nix 所有 config パターンで gateway 登録を宣言的化
  environment.etc."claude-code/managed-mcp.json".source = pkgs.replaceVars ./managed-mcp.json {
    inherit (cfg) gatewayUrl;
  };

  home-manager.users.${cfg.username} =
    { lib, ... }:
    {
      home.activation.seedClaudeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        seedConfig ".claude/settings.json" ./settings.json
      );
    };
}
