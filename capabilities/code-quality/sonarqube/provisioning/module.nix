{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "code-quality" config.dotfiles.capabilities.resolved;
  mkCommand = import ../../../../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
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
  config = lib.mkIf enabled {
    dotfiles.platform.cli.commands.sonarqube-provision = provisionAdmin;
    systemd.services.sonarqube-provision = {
      description = "SonarQube admin credential provisioning";
      after = [ "docker-sonarqube.service" ];
      wants = [ "docker-sonarqube.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = config.dotfiles.workstation.username;
        LoadCredential = [
          "admin-password:${config.dotfiles.capabilities.code-quality.sonarqube.credentials.adminPasswordFile}"
        ];
        Environment = [
          "SONARQUBE_URL=${config.dotfiles.platform.containers.services.sonarqube.endpoints.http.url}"
          "SONARQUBE_ADMIN_PASSWORD_FILE=%d/admin-password"
        ];
        ExecStart = lib.getExe provisionAdmin;
        TimeoutStartSec = "6min";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
        MemoryMax = "128M";
        TasksMax = 32;
        LimitCORE = 0;
      };
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
