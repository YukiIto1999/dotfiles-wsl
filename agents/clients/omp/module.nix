{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  projectMemoryEnabled = builtins.elem "project-memory" cfg.capabilities.resolved;
  lspProjection = import ../../impl/lsp.nix { inherit lib; };

  gatewayConfig = (pkgs.formats.json { }).generate "omp-mcp.json" {
    mcpServers.gateway = {
      type = "http";
      url = cfg.platform.mcp.gateway.url;
    };
  };

  lspConfig = (pkgs.formats.json { }).generate "omp-lsp.json" (lspProjection.omp cfg.toolchain.lsp);

  # omp は hook directory の中の symlink を読み込まない。Home Manager は file ごとに symlink を張るため、
  # directory ごと配備し、その中を実 file にする
  hookDirectory = pkgs.runCommandLocal "omp-hooks-pre" { } (
    ''
      mkdir "$out"
      cp ${./assets/verification-gate.ts} "$out/verification-gate.ts"
    ''
    + lib.optionalString projectMemoryEnabled ''
      cp ${
        pkgs.replaceVars ./assets/project-memory.ts {
          memoryBinary = lib.getExe cfg.capabilities.project-memory.runtime;
        }
      } "$out/project-memory.ts"
    ''
  );

  requiredSkillsFor =
    name:
    map (route: route.skill) (
      builtins.filter (
        route: route.subagent == name && route.activation == "required"
      ) cfg.agents.shared.routing.subagentSkills
    );

  buildSubagent =
    name: srcPath:
    let
      requiredSkills = builtins.toJSON (requiredSkillsFor name);
    in
    pkgs.runCommand "omp-agent-${name}.md"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnused
          pkgs.yq
        ];
        inherit requiredSkills;
      }
      ''
        test "$(head -n 1 ${srcPath})" = '---'
        closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' ${srcPath})
        test -n "$closing"
        sed -n "2,$((closing - 1))p" ${srcPath} > frontmatter.yaml
        tail -n "+$((closing + 1))" ${srcPath} > body.md

        rendered=$(yq -y --argjson requiredSkills "$requiredSkills" '
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
          | if ($requiredSkills | length) > 0
            then .autoloadSkills = $requiredSkills
            else del(.autoloadSkills)
            end
        ' frontmatter.yaml)
        {
          printf '%s\n' '---'
          printf '%s\n' "$rendered"
          printf '%s\n' '---'
          cat body.md
        } > "$out"
      '';
in
{
  dotfiles.agents.clients.omp = {
    binary = "omp";
    runtimeWrapperMode = "managed";
    rulesDestination = ".omp/agent/AGENTS.md";
    skillsDestination = ".omp/agent/skills";
    subagentMode = "rendered";
    subagentsDestination = ".omp/agent/agents";
    subagentFormat = "frontmatter-markdown";
    subagents = lib.mapAttrs buildSubagent cfg.agents.shared.subagents;
    gatewayConfig = {
      source = gatewayConfig;
      format = "json";
      managedFile = "mcp";
    };
    managedFiles = {
      config = {
        source = ./assets/config.seed.yml;
        format = "yaml";
        deployment = "seed";
        destination = ".omp/agent/config.yml";
      };
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
      hooks = {
        source = hookDirectory;
        format = "directory";
        deployment = "home";
        destination = ".omp/agent/hooks/pre";
      };
    };
    capabilityManagedFiles = {
      lsp = "lsp";
      projectMemory = if projectMemoryEnabled then "hooks" else null;
    };
    lspMode = "supported";
    telemetryMode = "unsupported";
    projectMemoryMode = if projectMemoryEnabled then "hooks" else "unsupported";
    skillProjectionMode = "preload";
    install = {
      kind = "github-release";
      updateOwner = "dotfiles";
      layout = "single-binary";
      assetFormat = "raw";
      repo = "can1357/oh-my-pi";
      retainedReleases = 2;
      releaseByArch = {
        x86_64 = {
          asset = "omp-linux-x64";
          entrypoint = "omp";
        };
        aarch64 = {
          asset = "omp-linux-arm64";
          entrypoint = "omp";
        };
      };
      requiredPaths = { };
    };
  };
}
