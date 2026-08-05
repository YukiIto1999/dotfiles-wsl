{ config, pkgs, ... }:

let
  cfg = config.my;
  mcpConfig = pkgs.replaceVars ./assets/mcp_config.json {
    gatewayUrl = config.dotfiles.mcp.gateway.url;
  };
in
{
  my.clis.antigravity = {
    binary = "agy";
    rulesFile = ".gemini/AGENTS.md";
    skillsDir = ".gemini/antigravity-cli/skills";
    agentsDir = null;
    buildAgent = null;
    gatewayFile = ".gemini/antigravity-cli/mcp_config.json";
    install = {
      kind = "installer-script";
      scriptUrl = "https://antigravity.google/cli/install.sh";
    };
  };

  my.artifacts."clis/antigravity/mcp" = {
    format = "json";
    source = mcpConfig;
  };

  home-manager.users.${cfg.username} = _: {
    home.file.".gemini/antigravity-cli/mcp_config.json".source = mcpConfig;
  };
}
