{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  mkCommand = import ../../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
  name = "dotfiles-agent-memory-harvest";
  model = "opencode-go/deepseek-v4.1-flash";
  fallback = "commandcode/deepseek/deepseek-v4.1-flash";
  thinking = "low";
  modelRouting = (pkgs.formats.yaml { }).generate "omp-memory-harvest-routing.yml" {
    enabledProviders = [
      "opencode-go"
      "commandcode"
    ];
    enabledModels = [
      model
      fallback
    ];
    advisor.enabled = false;
    retry = {
      enabled = true;
      modelFallback = true;
      fallbackOn = "any";
      maxRetries = 1;
      maxDelayMs = 1000;
      rateLimitWalksChain = true;
      waitForUsageReset = false;
      usageAwareFallback = false;
      fallbackChains = {
        "${model}:${thinking}" = [ "${fallback}:${thinking}" ];
        "${fallback}:${thinking}" = [ ];
        default = [ ];
      };
    };
  };
  worker = mkCommand {
    name = "${name}-worker";
    src = ./package/entry.sh;
    runtimeInputs = [ pkgs.git ];
    vars = {
      python = lib.getExe pkgs.python3;
      source = "${./package}";
      journal = "${../journal/package}";
      sessionsRoot = "${cfg.workstation.homeDir}/.omp/agent/sessions";
      stateFile = "${cfg.agents.runtime.state.root}/memory-harvest.json";
      lookbackDays = "7";
      memory = lib.getExe cfg.capabilities.project-memory.runtime;
      inherit model thinking;
      modelRouting = toString modelRouting;
    };
    extra.meta.mainProgram = "${name}-worker";
  };
  job = cfg.agents.job.mk {
    inherit name worker;
    description = "omp の利用者の訂正と決定を project memory に保存";
    # 一日分をまとめて読み、model の呼び出しを定額枠の中で日に数回へ抑える
    onCalendar = "*-*-* 07:00:00";
    executables.omp = cfg.agents.clientExecutables.omp;
    executionDependencies = cfg.agents.clientExecutionDependencies.omp ++ [
      cfg.capabilities.project-memory.runtime
    ];
  };
in
{
  options.dotfiles.agents.memoryHarvest.enable = lib.mkEnableOption "OMPの利用者発言からの記憶の収穫";

  config =
    lib.mkIf
      (
        cfg.agents.memoryHarvest.enable
        && builtins.elem "omp" cfg.agents.enabled
        && builtins.elem "project-memory" cfg.capabilities.resolved
      )
      {
        dotfiles.platform.cli.commands.agentMemoryHarvest = job.command;
        dotfiles.health.observations."agents/maintenance/memory-harvest" = job.observation;
        home-manager.users.${cfg.workstation.username}.systemd.user = job.units;
      };
}
