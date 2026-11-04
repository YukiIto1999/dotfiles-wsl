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
      # 定額枠の利用を前提とするため従量課金 model への切替は不可
      model = "opencode-go/deepseek-v4.1-flash";
      thinking = "low";
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
