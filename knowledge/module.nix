{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  ws = cfg.workstation;
  apiUrl = "http://127.0.0.1:3111";
  memory = pkgs.callPackage ./memory/package.nix { inherit apiUrl; };
  modelConfig = import ./omp-model-routing.nix { inherit pkgs; };
  sessionsRoot = "${ws.homeDir}/.omp/agent/sessions";
  limitSeconds = 6 * 60 * 60;

  /**
    非対話 job の worker
    name: worker の command 名
    template: `@name@` を vars の値で置き換える entry script
  */
  mkWorker =
    name: template: vars:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.git ];
      text = builtins.replaceStrings (map (key: "@${key}@") (
        builtins.attrNames vars
      )) (builtins.attrValues vars) (builtins.readFile template);
    };

  /**
    timer と手動の起動が同じ実行を共有する job。どちらも agents.slice の service として走り、
    上限時間を過ぎた走行は systemd が service の cgroup ごと止める。同時に二つは走らせない
  */
  mkJob =
    {
      name,
      description,
      worker,
      onCalendar,
    }:
    let
      busyStatus = 75;
      run = pkgs.writeShellScript "${name}-run" ''
        exec ${lib.getExe' pkgs.util-linux "flock"} --nonblock --conflict-exit-code ${toString busyStatus} \
          "''${XDG_RUNTIME_DIR:?}/${name}.lock" \
          ${lib.getExe worker} --omp ${cfg.agents.ompExecutable} "$@"
      '';
      environment = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" ];
    in
    {
      command = pkgs.writeShellApplication {
        inherit name;
        text = ''
          exec ${config.systemd.package}/bin/systemd-run --user --wait --pipe --collect --quiet \
            --slice=agents.slice --unit="${name}-manual-$$" \
            --property=RuntimeMaxSec=${toString limitSeconds} \
            ${lib.concatMapStrings (value: "--setenv=${value} ") environment}-- ${run} "$@"
        '';
      };
      services.${name} = {
        Unit = {
          Description = description;
          # 配備の切替は変わった unit を止めて起こし直す。oneshot の起動は完了まで戻らず、走行中の job があると切替が期限で失敗するため不可
          X-SwitchMethod = "keep-old";
        };
        Service = {
          Type = "oneshot";
          Slice = "agents.slice";
          ExecStart = toString run;
          KillMode = "control-group";
          TimeoutStartSec = limitSeconds;
          # 手動の走行と重なった定時の起動は失敗にしない
          SuccessExitStatus = busyStatus;
          Environment = environment;
        };
      };
      timers.${name} = {
        Unit.Description = "${description}の定時起動";
        Timer = {
          OnCalendar = onCalendar;
          Persistent = true;
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };

  journalName = "dotfiles-agent-journal";
  # 日付の区切り。深夜の作業を前日へ含めるため、暦日ではなく朝で切る
  journalStartHour = 6;
  journal = mkJob {
    name = journalName;
    description = "omp の技術的な知見を agent-journal に集積";
    onCalendar = "*-*-* ${lib.fixedWidthNumber 2 journalStartHour}:00:00";
    worker = mkWorker "${journalName}-worker" ./journal/package/entry.sh (
      modelConfig
      // {
        python = lib.getExe pkgs.python3;
        source = "${./journal/package}";
        zoneinfo = "${pkgs.tzdata}/share/zoneinfo";
        inherit sessionsRoot;
        journalDir = "${ws.environmentDir}/agent-journal";
        inherit (cfg.knowledge.journal) machineName;
        timeZone = config.time.timeZone;
        startHour = toString journalStartHour;
        lookbackDays = "7";
      }
    );
  };

  harvestName = "dotfiles-agent-memory-harvest";
  harvest = mkJob {
    name = harvestName;
    description = "omp の利用者の訂正と決定を project memory に保存";
    # 一日分をまとめて読み、model の呼び出しを定額枠の中で日に数回へ抑える
    onCalendar = "*-*-* 07:00:00";
    worker = mkWorker "${harvestName}-worker" ./harvest/package/entry.sh (
      modelConfig
      // {
        python = lib.getExe pkgs.python3;
        source = "${./harvest/package}";
        journal = "${./journal/package}";
        inherit sessionsRoot;
        stateFile = "${ws.homeDir}/.local/state/dotfiles-wsl/memory-harvest.json";
        lookbackDays = "7";
        memory = lib.getExe memory;
      }
    );
  };

  enabledJobs =
    lib.optional cfg.knowledge.journal.enable journal
    ++ lib.optional cfg.knowledge.harvest.enable harvest;

  # Hindsight の backend
  hindsightModels = import ./hindsight/models.nix { inherit pkgs; };
  hindsightRepository = "ghcr.io/vectorize-io/hindsight";
  hindsightVersion = "0.10.3";
  hindsightDigest = "sha256:5b6ef2b892703f0e82c448786349c88db60f06d8c9190432b68af00ce6dc45e3";
  commandCodeKey = "commandcode/api_key";
  commandCodeEnrolled = builtins.elem commandCodeKey cfg.secrets.paths;
in
{
  options.dotfiles.knowledge = {
    memory = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Hindsight を backend とする project memory の CLI `dotfiles-memory`。";
    };
    journal = {
      enable = lib.mkEnableOption "OMPの記録からの技術的な知見の集積";
      machineName = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*";
        default = config.networking.hostName;
        defaultText = lib.literalExpression "config.networking.hostName";
        description = "journal の file 名 `<yyyy>/<MMdd>/<機械名>.md` に使う機械名。既存の名前を引き継ぐ host は host の file で宣言する。";
      };
    };
    harvest.enable = lib.mkEnableOption "OMPの利用者発言からの記憶の収穫";
  };

  config = {
    dotfiles.knowledge.memory = memory;

    dotfiles.agents.mcpServers.memory = {
      command = lib.getExe memory;
      args = [ "mcp" ];
    };
    dotfiles.agents.omp.hooks."project-memory.ts" = pkgs.replaceVars ./memory/project-memory.ts {
      memoryBinary = lib.getExe memory;
    };

    environment.systemPackages = [ memory ];

    home-manager.users.${ws.username} = {
      home.packages = map (job: job.command) enabledJobs;
      systemd.user = lib.mkMerge (map (job: { inherit (job) services timers; }) enabledJobs);
    };

    virtualisation.oci-containers.containers.hindsight = {
      image = "${hindsightRepository}:${hindsightVersion}@${hindsightDigest}";
      environmentFiles = [ config.sops.templates."hindsight.env".path ];
      volumes = [
        "hindsight-data:/home/hindsight/.pg0"
        "${hindsightModels.embeddingRoot}:/opt/hindsight/models/embedding:ro"
        "${hindsightModels.rerankerRoot}:/opt/hindsight/models/reranker:ro"
      ];
      ports = [ "127.0.0.1:3111:3111" ];
      extraOptions = [
        "--init"
        # docker の既定の slice は上限の外のため、user.slice の上限の中へ置く
        "--cgroup-parent=${ws.memory.supportSlice}"
        "--memory=4g"
        "--shm-size=1g"
        "--stop-timeout=45"
      ];
    };
    systemd.services.docker-hindsight.serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = "5s";
      TimeoutStopSec = lib.mkForce "60s";
    };

    sops.secrets."opencode/go_api_key" = { };
    sops.secrets.${commandCodeKey} = lib.mkIf commandCodeEnrolled { };

    sops.templates."hindsight.env" = {
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "docker-hindsight.service" ];
      content = ''
        HINDSIGHT_API_HOST=0.0.0.0
        HINDSIGHT_API_PORT=3111
        HINDSIGHT_API_HEALTH_URL=http://localhost:3111/health/ready
        HINDSIGHT_API_DATABASE_URL=pg0
        # GoのMiniMaxはChat CompletionsではなくMessages APIを使う。
        HINDSIGHT_API_LLM_PROVIDER=anthropic
        HINDSIGHT_API_LLM_API_KEY=${config.sops.placeholder."opencode/go_api_key"}
        HINDSIGHT_API_LLM_BASE_URL=https://opencode.ai/inference/go/anthropic
        HINDSIGHT_API_LLM_MODEL=minimax-m3
        # Goはx-opencode-sessionの無い要求を400で拒否する。抽出は会話を持たないので配備で一つの値にする。
        HINDSIGHT_API_LLM_DEFAULT_HEADERS={"User-Agent":"hindsight/${hindsightVersion} (dotfiles-project-memory)","x-opencode-session":"dotfiles-project-memory"}
        HINDSIGHT_API_RETAIN_LLM_PROVIDER=openai
        HINDSIGHT_API_RETAIN_LLM_MODEL=deepseek-v4.1-flash
        HINDSIGHT_API_RETAIN_LLM_BASE_URL=https://opencode.ai/inference/go/openai/v1
        HINDSIGHT_API_FAIL_ON_EXTRACTION_ERRORS=true
        HINDSIGHT_API_EMBEDDINGS_PROVIDER=local
        HINDSIGHT_API_EMBEDDINGS_LOCAL_MODEL=/opt/hindsight/models/embedding
        HINDSIGHT_API_EMBEDDINGS_LOCAL_TRUST_REMOTE_CODE=false
        HINDSIGHT_API_RERANKER_PROVIDER=local
        HINDSIGHT_API_RERANKER_LOCAL_MODEL=/opt/hindsight/models/reranker
        HINDSIGHT_API_RERANKER_LOCAL_TRUST_REMOTE_CODE=false
        HINDSIGHT_API_ENABLE_BANK_CONFIG_API=true
        HINDSIGHT_API_LLM_OUTPUT_LANGUAGE=Japanese
        HINDSIGHT_API_WORKER_ID=dotfiles-hindsight
        HINDSIGHT_ENABLE_CP=false
        HF_HUB_OFFLINE=1
        TRANSFORMERS_OFFLINE=1
      ''
      + lib.optionalString commandCodeEnrolled ''
        HINDSIGHT_API_RETAIN_LLM_STRATEGY={"mode":"failover"}
        HINDSIGHT_API_RETAIN_LLM_MAX_RETRIES=0
        HINDSIGHT_API_RETAIN_LLM_1_PROVIDER=openai
        HINDSIGHT_API_RETAIN_LLM_1_API_KEY=${config.sops.placeholder.${commandCodeKey}}
        HINDSIGHT_API_RETAIN_LLM_1_BASE_URL=https://api.commandcode.ai/provider/v1
        HINDSIGHT_API_RETAIN_LLM_1_MODEL=deepseek/deepseek-v4.1-flash
        HINDSIGHT_API_RETAIN_LLM_1_DEFAULT_HEADERS={"User-Agent":"hindsight/${hindsightVersion} (dotfiles-project-memory)"}
        HINDSIGHT_API_RETAIN_LLM_1_MAX_RETRIES=1
      '';
    };
  };
}
