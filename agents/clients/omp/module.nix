{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  projectMemoryEnabled = builtins.elem "project-memory" cfg.capabilities.resolved;
  # tsgo と roslyn-ls の別実装向け設定継承を避けるため上流名の流用は不可
  lspNames = {
    bash = "bashls";
    csharp = "roslyn-ls";
    java = "jdtls";
    nix = "nixd";
    python = "ty";
    rust = "rust-analyzer";
    typescript = "tsgo";
  };

  gatewayConfig = (pkgs.formats.json { }).generate "omp-mcp.json" {
    mcpServers.gateway = {
      type = "http";
      url = cfg.platform.mcp.gateway.url;
    };
  };

  modelsConfig = (pkgs.formats.yaml { }).generate "omp-models.yml" {
    providers.typesafe = {
      baseUrl = "https://api.typesafe.ai";
      apiKey =
        "!sudo -n env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt "
        + "${lib.getExe pkgs.sops} --config "
        + lib.escapeShellArg "${cfg.workstation.dotfilesDir}/secrets/sops/assets/.sops.yaml"
        + " decrypt --extract '[\"typesafe\"][\"api_key\"]' "
        + lib.escapeShellArg "${cfg.workstation.dotfilesDir}/secrets/sops/assets/secrets.json";
    };
  };

  lspConfig = (pkgs.formats.json { }).generate "omp-lsp.json" (
    lib.mapAttrs' (
      name: server:
      lib.nameValuePair lspNames.${name} (
        {
          inherit (server) command args;
          fileTypes = builtins.attrNames server.extensions;
          rootMarkers = [ "." ];
        }
        // lib.optionalAttrs (server.initializationOptions != { }) {
          initOptions = server.initializationOptions;
        }
      )
    ) cfg.toolchain.lsp
  );

  # omp は hook directory の中の symlink を読み込まない。Home Manager は file ごとに symlink を張るため、
  # directory ごと配備し、その中を実 file にする
  hookDirectory = pkgs.runCommandLocal "omp-hooks-pre" { } (
    ''
      mkdir "$out"
      cp ${
        pkgs.replaceVars ./assets/verification-gate.ts {
          gateBinary = lib.getExe cfg.agents.packages.verificationGate;
        }
      } "$out/verification-gate.ts"
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
            elif . == "WebFetch" then empty
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
  dotfiles.agents.registry.omp = {
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
      models = {
        source = modelsConfig;
        format = "yaml";
        deployment = "seed";
        destination = ".omp/agent/models.yml";
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
