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

  encodeLsp =
    {
      command,
      args,
      extensions,
      initializationOptions,
    }:
    {
      command = [ command ] ++ args;
      extensions = builtins.attrNames extensions;
    }
    // lib.optionalAttrs (initializationOptions != { }) { initialization = initializationOptions; };
  # OpenCode は disable-model-invocation を読まない。skill の deny は model の候補と skill tool から外し、slash command には残す
  # 後に一致した rule が勝ち、key は名前順に並ぶため、先頭になる `*` に全体の許可を置く
  opencodePermission = {
    "*" = opencodeBase.permission;
  }
  // lib.optionalAttrs (cfg.agents.shared.explicitSkills != [ ]) {
    skill = {
      "*" = opencodeBase.permission;
    }
    // lib.genAttrs cfg.agents.shared.explicitSkills (_: "deny");
  };
  opencodeBaseWithLsp = (pkgs.formats.json { }).generate "opencode-base-with-lsp.json" (
    opencodeBase
    // {
      permission = opencodePermission;
      # 同名 built-in の root 解決を継承するため登録 ID の共用は不可
      lsp = lib.mapAttrs' (
        name: server: lib.nameValuePair "dotfiles-${name}" (encodeLsp (removeAttrs server [ "package" ]))
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

        # frontmatter の tools.skill は agent 側で skill を一括許可する rule になり全体の deny より後に効くため、同じ deny を agent にも置く
        tools=$(yq -y --argjson skill ${
          lib.escapeShellArg (builtins.toJSON (opencodePermission.skill or null))
        } '
          .tools |= (((. + ["Skill"]) | unique) | map({(ascii_downcase):true}) | add)
          | if $skill == null then . else .permission.skill = $skill end
        ' frontmatter.yaml)
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
