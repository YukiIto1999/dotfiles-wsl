{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles;
  opencodeBase = builtins.fromJSON (builtins.readFile ./assets/opencode.json);

  opencodeBaseWithLsp = (pkgs.formats.json { }).generate "opencode-base-with-lsp.json" (
    opencodeBase
    // {
      lsp = lib.mapAttrs (
        _: server:
        {
          command = [ server.command ] ++ server.args;
          extensions = builtins.attrNames server.extensions;
        }
        // lib.optionalAttrs (server.initializationOptions != { }) {
          initialization = server.initializationOptions;
        }
      ) cfg.toolchain.lsp;
    }
  );
  opencodeGatewayConfig = (pkgs.formats.json { }).generate "opencode-gateway.json" {
    mcp.gateway = {
      type = "remote";
      url = config.dotfiles.mcp.gateway.url;
    };
  };
  opencodeConfig = pkgs.runCommandLocal "opencode.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
    jq --sort-keys --slurp '.[0] * .[1]' ${opencodeBaseWithLsp} ${opencodeGatewayConfig} > "$out"
  '';

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
    pkgs.runCommand "${name}.md"
      {
        nativeBuildInputs = [ pkgs.yq ];
        inherit (fm) frontmatter body;
      }
      ''
        tools=$(yq -y '.tools |= (map({(ascii_downcase):true}) | add)' <<<"$frontmatter")
        {
          printf '%s\n' '---'
          printf '%s\n' "$tools"
          printf '%s\n' '---'
          printf '%s\n' "$body"
        } > "$out"
      '';
in
{
  dotfiles.agents.clients.opencode = {
    binary = "opencode";
    rulesDestination = ".config/opencode/AGENTS.md";
    skillsDestination = ".config/opencode/skills";
    definitionMode = "rendered";
    definitionsDestination = ".config/opencode/agents";
    definitionFormat = "frontmatter-markdown";
    definitions = lib.mapAttrs buildAgent cfg.agents.shared.definitions;
    gatewayConfig = {
      source = opencodeGatewayConfig;
      format = "json";
      managedFile = "config";
    };
    managedFiles = {
      config = {
        source = opencodeConfig;
        format = "json";
        deployment = "home";
        destination = ".config/opencode/opencode.json";
      };
      agentmemory-plugin = {
        source = config.dotfiles.containers.agentmemory.clients.opencodePlugin;
        format = "text";
        deployment = "home";
        destination = ".config/opencode/plugins/agentmemory-capture.ts";
      };
    };
    capabilityManagedFiles = {
      lsp = "config";
      agentmemory = "agentmemory-plugin";
    };
    lspMode = "supported";
    telemetryMode = "unsupported";
    agentmemoryMode = "plugin";
    install = {
      kind = "github-release";
      updateOwner = "dotfiles";
      layout = "single-binary";
      repo = "anomalyco/opencode";
      retainedReleases = 2;
      releaseByArch = {
        x86_64 = {
          asset = "opencode-linux-x64.tar.gz";
          entrypoint = "opencode";
        };
        aarch64 = {
          asset = "opencode-linux-arm64.tar.gz";
          entrypoint = "opencode";
        };
      };
      requiredPaths = { };
    };
  };
}
