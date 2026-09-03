{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkCommand = import ../../../../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
  serverPort = "9000";
  provisionAdmin = mkCommand {
    name = "dotfiles-sonarqube-provision";
    src = ./impl/provision-admin.sh;
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
    ];
  };
in
{
  config = {
    systemd.services.sonarqube-provision = {
      description = "SonarQube admin credential provisioning";
      after = [ "docker-sonarqube.service" ];
      wants = [ "docker-sonarqube.service" ];
      # 外部 service の受理条件で activation 全体を止めない。
      wantedBy = [ ];
      serviceConfig = {
        Type = "oneshot";
        # 反復 timer が毎回 unit を起動できるよう、成功後は inactive に戻す。
        RemainAfterExit = false;
        User = config.dotfiles.workstation.username;
        Environment = [
          "SONARQUBE_URL=http://127.0.0.1:${serverPort}"
          "SONARQUBE_ADMIN_PASSWORD_FILE=${config.dotfiles.capabilities.code-quality.sonarqube.credentials.adminPasswordFile}"
        ];
        ExecStart = lib.getExe provisionAdmin;
        # cold start の timeout 後も、admin/admin を残さず再試行する。
        Restart = "on-failure";
        RestartSec = "60s";
      };
      startLimitIntervalSec = 0;
    };

    systemd.timers.sonarqube-provision = {
      description = "SonarQube admin credential provisioning";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "1h";
      };
    };
  };
}
