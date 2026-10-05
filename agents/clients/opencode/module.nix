{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles;
  projectMemoryEnabled = builtins.elem "project-memory" cfg.capabilities.resolved;
  opencodeBase = builtins.fromJSON (builtins.readFile ./assets/opencode.json);

  opencodeBaseWithLsp = (pkgs.formats.json { }).generate "opencode-base-with-lsp.json" (
    opencodeBase
    // {
      # 同名 built-in の root 解決を継承するため登録 ID の共用は不可
      lsp = lib.mapAttrs' (
        name: server:
        lib.nameValuePair "dotfiles-${name}" (
          {
            command = [ server.command ] ++ server.args;
            extensions = builtins.attrNames server.extensions;
          }
          // lib.optionalAttrs (server.initializationOptions != { }) {
            initialization = server.initializationOptions;
          }
        )
      ) cfg.toolchain.lsp;
    }
  );
  opencodeGatewayConfig = (pkgs.formats.json { }).generate "opencode-gateway.json" {
    mcp.gateway = {
      type = "remote";
      url = config.dotfiles.platform.mcp.gateway.url;
    };
  };
  opencodeConfig = pkgs.runCommandLocal "opencode.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
    jq --sort-keys --slurp '.[0] * .[1]' ${opencodeBaseWithLsp} ${opencodeGatewayConfig} > "$out"
  '';

  buildSubagent =
    name: srcPath:
    pkgs.runCommand "${name}.md"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnused
          pkgs.yq
        ];
      }
      ''
        test "$(head -n 1 ${srcPath})" = '---'
        closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' ${srcPath})
        test -n "$closing"
        sed -n "2,$((closing - 1))p" ${srcPath} > frontmatter.yaml
        tail -n "+$((closing + 1))" ${srcPath} > body.md

        tools=$(yq -y '.tools |= (((. + ["Skill"]) | unique) | map({(ascii_downcase):true}) | add)' frontmatter.yaml)
        {
          printf '%s\n' '---'
          printf '%s\n' "$tools"
          printf '%s\n' '---'
          cat body.md
        } > "$out"
      '';
in
{
  dotfiles.agents.registry.opencode = {
    binary = "opencode";
    runtimeWrapperMode = "managed";
    rulesDestination = ".config/opencode/AGENTS.md";
    skillsDestination = ".config/opencode/skills";
    subagentMode = "rendered";
    subagentsDestination = ".config/opencode/agents";
    subagentFormat = "frontmatter-markdown";
    subagents = lib.mapAttrs buildSubagent cfg.agents.shared.subagents;
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
    }
    // lib.optionalAttrs projectMemoryEnabled {
      project-memory-plugin = {
        source = config.dotfiles.capabilities.project-memory.clientIntegrations.opencodePlugin;
        format = "text";
        deployment = "home";
        destination = ".config/opencode/plugins/project-memory.ts";
      };
    };
    capabilityManagedFiles = {
      lsp = "config";
      projectMemory = if projectMemoryEnabled then "project-memory-plugin" else null;
    };
    lspMode = "supported";
    telemetryMode = "unsupported";
    projectMemoryMode = if projectMemoryEnabled then "plugin" else "unsupported";
    skillProjectionMode = "dynamic";
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
