{
  config,
  lib,
  omp,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  mkOmpPackage = import ./package.nix;
  ompPackage = mkOmpPackage { inherit lib omp pkgs; };
  lspProjection = import ../impl/lsp.nix { inherit lib; };

  gatewayConfig = (pkgs.formats.json { }).generate "omp-mcp.json" {
    mcpServers.gateway = {
      type = "http";
      url = cfg.mcp.gateway.url;
    };
  };

  lspConfig = (pkgs.formats.json { }).generate "omp-lsp.json" (lspProjection.omp cfg.toolchain.lsp);

  splitFrontmatter =
    src:
    let
      parts = lib.splitString "\n---\n" (builtins.readFile src);
    in
    {
      frontmatter = lib.removePrefix "---\n" (builtins.head parts);
      body = lib.concatStringsSep "\n---\n" (builtins.tail parts);
    };

  buildAgent =
    name: srcPath:
    let
      fm = splitFrontmatter srcPath;
    in
    pkgs.runCommand "omp-agent-${name}.md"
      {
        nativeBuildInputs = [ pkgs.yq ];
        inherit (fm) frontmatter body;
      }
      ''
        rendered=$(yq -y '
          .tools |= map(
            if . == "Read" then "read"
            elif . == "Grep" then "grep"
            elif . == "Glob" then "glob"
            elif . == "WebSearch" then "web_search"
            elif . == "Edit" then "edit"
            elif . == "Write" then "write"
            elif . == "Bash" then "bash"
            else error("unsupported OMP agent tool: " + .)
            end
          )
          | if has("effort") then .["thinking-level"] = .effort | del(.effort) else . end
        ' <<<"$frontmatter")
        {
          printf '%s\n' '---'
          printf '%s\n' "$rendered"
          printf '%s\n' '---'
          printf '%s' "$body"
        } > "$out"
      '';
in
{
  dotfiles.agents.clients.omp = {
    binary = "omp";
    package = ompPackage;
    runtimeWrapperMode = "managed";
    rulesDestination = ".omp/agent/AGENTS.md";
    skillsDestination = ".omp/agent/skills";
    definitionMode = "rendered";
    definitionsDestination = ".omp/agent/agents";
    definitionFormat = "frontmatter-markdown";
    definitions = lib.mapAttrs buildAgent cfg.agents.shared.definitions;
    gatewayConfig = {
      source = gatewayConfig;
      format = "json";
      managedFile = "mcp";
    };
    managedFiles = {
      mcp = {
        source = gatewayConfig;
        format = "json";
        deployment = "home";
        destination = ".omp/agent/mcp.json";
      };
      lsp = {
        source = lspConfig;
        format = "json";
        deployment = "home";
        destination = ".omp/agent/lsp.json";
      };
      agentmemory-hook = {
        source = ./assets/agentmemory.ts;
        format = "text";
        deployment = "home";
        destination = ".omp/agent/hooks/pre/agentmemory.ts";
      };
    };
    capabilityManagedFiles = {
      lsp = "lsp";
      agentmemory = "agentmemory-hook";
    };
    lspMode = "supported";
    telemetryMode = "unsupported";
    agentmemoryMode = "hooks";
    install = {
      kind = "nix-package";
      updateOwner = "flake-lock";
      layout = "nix-store";
    };
  };
}
