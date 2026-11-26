{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  ws = cfg.workstation;
  ompDirectory = "${ws.homeDir}/.omp/agent";

  # tsgo と roslyn-ls の別実装向け設定継承を避けるため上流名の流用は不可
  compatibleLspNames = {
    bash = "bashls";
    csharp = "roslyn-ls";
    java = "jdtls";
    nix = "nixd";
    python = "ty";
    rust = "rust-analyzer";
    typescript = "tsgo";
  };
  encodeLsp =
    {
      command,
      args,
      extensions,
      initializationOptions,
    }:
    {
      inherit command args;
      fileTypes = builtins.attrNames extensions;
      rootMarkers = [ "." ];
    }
    // lib.optionalAttrs (initializationOptions != { }) { initOptions = initializationOptions; };
  lspConfig = (pkgs.formats.json { }).generate "omp-lsp.json" (
    lib.mapAttrs' (
      name: server:
      lib.nameValuePair (compatibleLspNames.${name} or "dotfiles-${name}") (
        encodeLsp (removeAttrs server [ "package" ])
      )
    ) cfg.toolchain.lsp
  );

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
    + lib.escapeShellArg "${ws.dotfilesDir}/secrets/sops/assets/.sops.yaml"
    + " decrypt --extract "
    + lib.escapeShellArg ''["${provider}"]["api_key"]''
    + " "
    + lib.escapeShellArg "${ws.dotfilesDir}/secrets/sops/assets/secrets.json";

  webCredentials = lib.genAttrs [ "keenable" "exa" ] (provider: {
    apiKey = keyFromSops provider;
  });
  modelsSeed = (pkgs.formats.yaml { }).generate "omp-models.yml" {
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

  # config.yml は利用者と OMP が書き換える。無いときだけ seed を置く。
  # models.yml は既存の provider を残したまま、宣言した任意 provider の欠けを補い、web 検索の資格情報の取得方法をそろえる
  installOmpFiles = pkgs.writeShellApplication {
    name = "dotfiles-omp-files";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.jq
      pkgs.yq
    ];
    text = ''
      directory=${lib.escapeShellArg ompDirectory}
      seed() {
        if [ ! -e "$directory/$1" ] && [ ! -L "$directory/$1" ]; then
          install -Dm600 "$2" "$directory/$1"
        fi
      }
      seed config.yml ${./config.seed.yml}
      seed models.yml ${modelsSeed}

      models=$directory/models.yml
      [ -f "$models" ] && [ ! -L "$models" ] || exit 0
      scratch=$(mktemp -d)
      trap 'rm -rf -- "$scratch"' EXIT
      yq -c . "$models" > "$scratch/input"
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
        ' "$scratch/input" > "$scratch/merged"
      if ! cmp -s "$scratch/input" "$scratch/merged"; then
        yq -y . "$scratch/merged" > "$scratch/output"
        chmod 600 "$scratch/output"
        mv -T -- "$scratch/output" "$models"
      fi
    '';
  };
in
{
  home-manager.users.${ws.username} =
    { lib, ... }:
    {
      home.file = {
        ".omp/agent/lsp.json".source = lspConfig;
        ".omp/agent/WATCHDOG.yml".source = ./watchdog.yml;
      };
      home.activation.ompFiles = lib.hm.dag.entryAfter [ "writeBoundary" ] (lib.getExe installOmpFiles);
    };
}
