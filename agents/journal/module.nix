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
  journal = mkCommand {
    inherit name;
    src = ./package/entry.sh;
    runtimeInputs = [ pkgs.git ];
    vars = {
      python = lib.getExe pkgs.python3;
      source = "${./package}";
      zoneinfo = "${pkgs.tzdata}/share/zoneinfo";
      sessionsRoot = "${cfg.workstation.homeDir}/.omp/agent/sessions";
      journalDir = "${cfg.workstation.environmentDir}/agent-journal";
      host = config.networking.hostName;
      timeZone = config.time.timeZone;
      startHour = toString startHour;
      lookbackDays = "7";
      omp = cfg.agents.clientExecutables.omp;
      model = "opencode-go/deepseek-v4.1-flash";
      thinking = "low";
    };
    extra.meta.mainProgram = name;
  };
in
{
  config = lib.mkIf (builtins.elem "omp" cfg.agents.enabled) {
    dotfiles.platform.cli.commands.agentJournal = journal;

    dotfiles.health.observations."agents/maintenance/journal" = {
      kind = "systemd-timer";
      checkId = "maintenance/${name}.timer";
      resourceKey = null;
      timeoutSeconds = 10;
      failureMessage = "${name}.timer or its service is not operational";
      timer = "${name}.timer";
      service = "${name}.service";
      unitFileStates = [
        "enabled"
        "enabled-runtime"
      ];
      activeStates = [ "active" ];
      serviceResults = [ "success" ];
    };

    systemd.services.${name} = {
      description = "omp の作業日誌を agent-journal に記録";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.workstation.username;
        # 次の 06:00 に前回の実行が残っていると timer は起動しない。記録済みの日は一日ごとに push 済みなので、
        # 打ち切っても失うのは途中の一日だけで、次の実行が拾い直す
        TimeoutStartSec = "6h";
        Environment = [
          "HOME=${cfg.workstation.homeDir}"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        ];
        ExecStart = lib.getExe journal;
      };
    };

    systemd.timers.${name} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* ${lib.fixedWidthNumber 2 startHour}:00:00";
        Persistent = true;
      };
    };
  };
}
