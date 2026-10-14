{ config, pkgs, ... }:

let
  mcpConfig = pkgs.replaceVars ./assets/mcp_config.json {
    gatewayUrl = config.dotfiles.platform.mcp.gateway.url;
  };
in
{
  dotfiles.agents.registry.antigravity = {
    binary = "agy";
    supply.package = "antigravity-cli";
    runtime.unsupported = { };
    rules.file.destination = ".gemini/AGENTS.md";
    skillsDestination = ".gemini/antigravity-cli/skills";
    subagents.unsupported = { };
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
    lsp.unsupported = { };
    telemetry.unsupported = { };
    projectMemory.unsupported = { };
  };
}
