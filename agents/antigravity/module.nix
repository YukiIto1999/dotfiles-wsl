{ config, pkgs, ... }:

let
  mcpConfig = pkgs.replaceVars ./assets/mcp_config.json {
    gatewayUrl = config.dotfiles.mcp.gateway.url;
  };
in
{
  dotfiles.agents.clients.antigravity = {
    binary = "agy";
    rulesDestination = ".gemini/AGENTS.md";
    skillsDestination = ".gemini/antigravity-cli/skills";
    definitionMode = "unsupported";
    definitionsDestination = null;
    definitionFormat = null;
    definitions = { };
    gatewayConfig = {
      source = mcpConfig;
      format = "json";
      managedFile = "mcp";
    };
    managedFiles.mcp = {
      source = mcpConfig;
      format = "json";
      deployment = "home";
      destination = ".gemini/antigravity-cli/mcp_config.json";
    };
    capabilityManagedFiles = { };
    lspMode = "unsupported";
    telemetryMode = "unsupported";
    agentmemoryMode = "unsupported";
    install = {
      kind = "installer-script";
      scriptUrl = "https://antigravity.google/cli/install.sh";
    };
  };
}
