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
    supply.package = "opencode";
    runtime.managed = { };
    rules.file.destination = ".config/opencode/AGENTS.md";
    skillsDestination = ".config/opencode/skills";
    subagents.rendered = {
      destination = ".config/opencode/agents";
      sources = lib.mapAttrs buildSubagent cfg.agents.shared.subagents;
      skillProjection = "dynamic";
    };
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
    lsp.supported.managedFile = "config";
    telemetry.unsupported = { };
    projectMemory =
      if projectMemoryEnabled then
        { plugin.managedFile = "project-memory-plugin"; }
      else
        { unsupported = { }; };
  };
}
