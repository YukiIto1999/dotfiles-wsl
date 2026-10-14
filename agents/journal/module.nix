{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  mkCommand = import ../../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
  name = "dotfiles-agent-journal";
  # 日付の区切り。深夜の作業を前日へ含めるため、暦日ではなく朝で切る
  startHour = 6;
  worker = mkCommand {
    name = "${name}-worker";
    src = ./package/entry.sh;
    runtimeInputs = [ pkgs.git ];
    vars = {
      python = lib.getExe pkgs.python3;
      source = "${./package}";
      zoneinfo = "${pkgs.tzdata}/share/zoneinfo";
      sessionsRoot = "${cfg.workstation.homeDir}/.omp/agent/sessions";
      journalDir = "${cfg.workstation.environmentDir}/agent-journal";
      inherit (cfg.agents.journal) machineName;
      timeZone = config.time.timeZone;
      startHour = toString startHour;
      lookbackDays = "7";
      model = "opencode-go/deepseek-v4.1-flash";
      thinking = "low";
    };
    extra.meta.mainProgram = "${name}-worker";
  };
  job = cfg.agents.job.mk {
    inherit name worker;
    description = "omp の作業日誌を agent-journal に記録";
    onCalendar = "*-*-* ${lib.fixedWidthNumber 2 startHour}:00:00";
    executables.omp = cfg.agents.clientExecutables.omp;
    executionDependencies = cfg.agents.clientExecutionDependencies.omp;
  };
in
{
  options.dotfiles.agents.journal.enable = lib.mkEnableOption "OMPの作業日誌の生成";

  options.dotfiles.agents.journal.machineName = lib.mkOption {
    type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*";
    default = config.networking.hostName;
    defaultText = lib.literalExpression "config.networking.hostName";
    description = "作業日誌の file 名 `<yyyy>/<MMdd>/<機械名>.md` に使う機械名。既存の日誌の名前を引き継ぐ host は profile で宣言する。";
  };

  config = lib.mkIf (cfg.agents.journal.enable && builtins.elem "omp" cfg.agents.enabled) {
    dotfiles.platform.cli.commands.agentJournal = job.command;
    dotfiles.health.observations."agents/maintenance/journal" = job.observation;
    home-manager.users.${cfg.workstation.username}.systemd.user = job.units;
  };
}
