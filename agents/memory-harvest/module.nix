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
  harvest = mkCommand {
    inherit name;
    src = ./package/entry.sh;
    runtimeInputs = [ pkgs.git ];
    vars = {
      python = lib.getExe pkgs.python3;
      source = "${./package}";
      # session 記録の読み方と model の呼び方は作業日誌と共有する
      journal = "${../journal/package}";
      sessionsRoot = "${cfg.workstation.homeDir}/.omp/agent/sessions";
      stateFile = "${cfg.agents.runtime.state.root}/memory-harvest.json";
      lookbackDays = "7";
      memory = lib.getExe cfg.capabilities.project-memory.runtime;
      omp = cfg.agents.clientExecutables.omp;
      # 作業日誌と同じ定額の model を使い、従量課金の経路へ流さない
      model = "opencode-go/deepseek-v4.1-flash";
      thinking = "low";
    };
    extra.meta.mainProgram = name;
  };
in
{
  config =
    lib.mkIf
      (builtins.elem "omp" cfg.agents.enabled && builtins.elem "project-memory" cfg.capabilities.resolved)
      {
        dotfiles.platform.cli.commands.agentMemoryHarvest = harvest;

        dotfiles.health.observations."agents/maintenance/memory-harvest" = {
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
          description = "omp の利用者の訂正と決定を project memory に保存";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            User = cfg.workstation.username;
            # 打ち切った実行は読み終えた位置を進めないので、次の実行が同じ範囲を読み直す
            TimeoutStartSec = "6h";
            Environment = [
              "HOME=${cfg.workstation.homeDir}"
              "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
            ];
            ExecStart = lib.getExe harvest;
          };
        };

        # 一日分をまとめて読み、model の呼び出しを定額枠の中で日に数回へ抑える
        systemd.timers.${name} = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 07:00:00";
            Persistent = true;
          };
        };
      };
}
