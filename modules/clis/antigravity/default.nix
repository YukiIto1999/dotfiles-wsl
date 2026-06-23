{ config, pkgs, ... }:

let
  cfg = config.my;
in
{
  my.clis.antigravity = {
    binary      = "agy";
    rulesFile   = ".gemini/AGENTS.md";
    skillsDir   = ".gemini/antigravity-cli/skills";
    agentsDir   = null;
    buildAgent  = null;
    gatewayFile = ".gemini/antigravity-cli/mcp_config.json";
    install     = {
      kind      = "installer-script";
      scriptUrl = "https://antigravity.google/cli/install.sh";
    };
  };

  home-manager.users.${cfg.username} = { ... }: {
    home.file.".gemini/antigravity-cli/mcp_config.json".source =
      pkgs.replaceVars ./mcp_config.json { inherit (cfg) gatewayUrl; };
  };
}
