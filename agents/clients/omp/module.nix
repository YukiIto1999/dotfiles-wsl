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

  # server が配る instructions は全 session と subagent の prompt へ入り、Skill を入口にする経路と別の初手を指示するため載せない
  gatewayConfig = (pkgs.formats.json { }).generate "omp-mcp.json" {
    mcpServers.gateway = {
      type = "http";
      url = cfg.platform.mcp.gateway.url;
      instructions = false;
    };
  };

  keyFromEnvironment = name: "!${lib.getExe' pkgs.coreutils "printenv"} ${name}";
  optionalModelProviders = {
    refuseless = {
      baseUrl = "https://api.refuseless.com/v1";
      apiKey = keyFromEnvironment "REFUSELESS_API_KEY";
      api = "openai-completions";
      discovery.type = "openai-models-list";
    };
    orcarouter = {
      baseUrl = "https://api.orcarouter.ai/v1";
      apiKey = keyFromEnvironment "ORCAROUTER_API_KEY";
      api = "openai-completions";
      models = [
        {
          id = "openai/gpt-4o-mini";
          contextWindow = 128000;
          input = [
            "text"
            "image"
          ];
        }
        {
          id = "openai/gpt-6.1-sol";
          contextWindow = 1050000;
          input = [
            "text"
            "image"
          ];
          reasoning = true;
        }
        {
          id = "anthropic/claude-sonnet-5.5";
          contextWindow = 1000000;
          input = [
            "text"
            "image"
          ];
          reasoning = true;
        }
      ];
    };
    arliai = {
      baseUrl = "https://api.arliai.com/v1";
      apiKey = keyFromEnvironment "ARLIAI_API_KEY";
      api = "openai-completions";
      models = [
        {
          id = "DeepSeek-V4.1-Flash-1017";
          contextWindow = 524288;
          input = [
            "text"
            "image"
          ];
          reasoning = true;
          thinking = {
            mode = "effort";
            efforts = [
              "high"
              "max"
            ];
          };
        }
        {
          id = "Qwen3.8-27B";
          contextWindow = 262144;
          input = [
            "text"
            "image"
          ];
          reasoning = true;
        }
      ];
    };
  };

  keyFromSops =
    provider:
    "!sudo -n env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt "
    + "${lib.getExe pkgs.sops} --config "
    + lib.escapeShellArg "${cfg.workstation.dotfilesDir}/secrets/sops/assets/.sops.yaml"
    + " decrypt --extract "
    + lib.escapeShellArg ''["${provider}"]["api_key"]''
    + " "
    + lib.escapeShellArg "${cfg.workstation.dotfilesDir}/secrets/sops/assets/secrets.json";

  webCredentials = lib.genAttrs [ "keenable" "exa" ] (provider: {
    apiKey = keyFromSops provider;
  });
  configSeed = ./assets/config.seed.yml;
  modelsConfig = (pkgs.formats.yaml { }).generate "omp-models.yml" {
    providers =
      optionalModelProviders
      // webCredentials
      // {
        typesafe = {
          baseUrl = "https://api.typesafe.ai";
          apiKey = keyFromSops "typesafe";
        };
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

  implementer = pkgs.writeText "omp-agent-implementer.md" ''
    ---
    name: implementer
    description: 受入条件と変更範囲が確定した実装を別のモデル経路で実行する。
    tools: [read, grep, glob, edit, write, bash]
    ---

    親から受け取った対象、変更範囲、守る契約、受入条件に従って実装する。
    実装と検証は該当する Skill に従い、親が担当する統合と最終判定は親に残す。
    範囲や期待値の変更が必要なら、実装せず根拠を親へ返す。
    差分、実測した確認結果、未確認事項を親へ返す。
  '';

  mkSeedMigration =
    name: migrate:
    pkgs.writeShellApplication {
      name = "dotfiles-migrate-omp-${name}";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.jq
        pkgs.yq
      ];
      text = ''
        target=$1
        directory=''${target%/*}
        die() {
          printf 'dotfiles-migrate-omp-${name}: %s\n' "$1" >&2
          exit 70
        }
        if [[ ! -e $target && ! -L $target ]]; then exit 0; fi
        [[ ! -L $directory && -d $directory && -O $directory ]] \
          || die 'unsafe configuration directory'
        [[ ! -L $target && -f $target && -O $target ]] \
          || die 'unsafe configuration file'
        identity=$(stat -c '%d:%i:%u:%a' -- "$directory" "$target")
        scratch=$(mktemp -d -- "$directory/.omp-config.XXXXXXXX")
        trap 'rm -rf -- "$scratch"' EXIT
        cp -- "$target" "$scratch/original"
        yq -cs '
          if length == 1 and (.[0] | type) == "object" then .[0]
          else error("expected one configuration object") end
        ' "$scratch/original" > "$scratch/input"
        ${migrate}
        if cmp -s "$scratch/input" "$scratch/migrated"; then exit 0; fi
        yq -y '.' "$scratch/migrated" > "$scratch/output"
        chmod 600 "$scratch/output"
        if [[ -L $directory || -L $target || $(stat -c '%d:%i:%u:%a' -- "$directory" "$target") != "$identity" ]] \
          || ! cmp -s "$target" "$scratch/original"; then
          die 'configuration changed while preparing migration'
        fi
        mv -T -- "$scratch/output" "$target"
      '';
    };

  migrateConfig = mkSeedMigration "config" ''
    yq -c . ${configSeed} > "$scratch/seed"
    cat > "$scratch/migration.jq" <<'JQ'
      if .["x-dotfiles"]["model-routing"] == true then .
      else
        $seed[0] as $routes
        | del(
            .modelRoles.dev, .modelRoles.plan, .modelRoles.task, .modelRoles.vision,
            .modelRoles.memory, .modelRoles.speech, .modelRoles.dictation,
            .retry.fallbackChains.dev, .retry.fallbackChains.plan, .retry.fallbackChains.task,
            .retry.fallbackChains.vision, .retry.fallbackChains.memory, .retry.fallbackChains.speech,
            .retry.fallbackChains.dictation, .retry.fallbackChains["web/*"],
            .task.agentModelOverrides.task,
            .providers.webSearch, .providers.webSearchOrder, .providers.webSearchExclude,
            .providers.webSearchGeminiModel
          )
        | if .task.agentModelOverrides.security == $oldReview
          then del(.task.agentModelOverrides.security) else . end
        | .modelRoles |= ({default: $routes.modelRoles.default} + . + ($routes.modelRoles | del(.default)))
        | .retry.fallbackChains += $routes.retry.fallbackChains
        | .retry.modelFallback = $routes.retry.modelFallback
        | .task.agentModelOverrides += $routes.task.agentModelOverrides
        | if .advisor.syncBacklog == "1" then del(.advisor.syncBacklog) else . end
        | .advisor.enabled = $routes.advisor.enabled
        | .generate_image.enabled = $routes.generate_image.enabled
        | if any(.. | scalars; . == "@dev" or . == "pi/dev")
            or ((.cycleOrder // []) | any(. == "dev"))
          then error("the retired dev role still has a separate reference") else . end
        | .["x-dotfiles"]["model-routing"] = $routes["x-dotfiles"]["model-routing"]
      end
    JQ
    jq -cf "$scratch/migration.jq" --arg oldReview 'openai-codex/gpt-6.1-sol:xhigh' --slurpfile seed "$scratch/seed" \
      "$scratch/input" > "$scratch/migrated"
  '';

  migrateModels = mkSeedMigration "models" ''
    jq -c \
      --argjson optional ${lib.escapeShellArg (builtins.toJSON optionalModelProviders)} \
      --argjson web ${lib.escapeShellArg (builtins.toJSON webCredentials)} '
        if .providers != null and (.providers | type) != "object"
        then error("OMP model providers must be a mapping")
        else (.providers // {}) as $existing
          | .providers = ($optional + $existing)
          | reduce ($web | to_entries[]) as $provider (.;
              .providers[$provider.key].apiKey = $provider.value.apiKey)
        end
      ' "$scratch/input" > "$scratch/migrated"
  '';
in
{
  dotfiles.agents.registry.omp = {
    binary = "omp";
    supply.package = "omp";
    runtime.managed.argumentGuard = builtins.readFile ./assets/guard-arguments.sh;
    rules.file = {
      destination = ".omp/agent/AGENTS.md";
      # omp の task subagent は AGENTS.md を継承せず、RULES.md だけを読む
      constraintsDestination = ".omp/agent/RULES.md";
    };
    skillsDestination = ".omp/agent/skills";
    subagents.rendered = {
      destination = ".omp/agent/agents";
      sources = { inherit implementer; };
      skillProjection = "preload";
    };
    gatewayConfig = {
      source = gatewayConfig;
      format = "json";
      managedFile = "mcp";
    };
    managedFiles = {
      config = {
        source = configSeed;
        format = "yaml";
        deployment = "seed";
        destination = ".omp/agent/config.yml";
        seedMigrationCommand = migrateConfig;
      };
      models = {
        source = modelsConfig;
        format = "yaml";
        deployment = "seed";
        destination = ".omp/agent/models.yml";
        seedMigrationCommand = migrateModels;
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
    lsp.supported.managedFile = "lsp";
    telemetry.unsupported = { };
    projectMemory =
      if projectMemoryEnabled then { hooks.managedFile = "hooks"; } else { unsupported = { }; };
  };
}
