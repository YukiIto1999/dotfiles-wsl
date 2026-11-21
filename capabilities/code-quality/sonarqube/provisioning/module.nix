{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "code-quality" config.dotfiles.capabilities.resolved;
  mkCommand = import ../../../../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
  lifecycle = config.dotfiles.capabilities.code-quality.sonarqube.lifecycle;
  backend = config.dotfiles.platform.containers.services.sonarqube;
  serverUnit = "docker-sonarqube.service";
  provisionUnit = "sonarqube-provision.service";
  startGuardUnit = "sonarqube-start-guard.service";
  frontUnit = "${config.dotfiles.platform.mcp.fronts.sonarqube.service}.service";
  adminCredential = "admin-password:${config.dotfiles.capabilities.code-quality.sonarqube.credentials.adminPasswordFile}";
  credentialEnvironment = [
    "SONARQUBE_URL=${backend.endpoints.http.url}"
    "SONARQUBE_ADMIN_PASSWORD_FILE=%d/admin-password"
  ];
  sandbox = {
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
    LimitCORE = 0;
  };
  provisionAdmin = mkCommand {
    name = "dotfiles-sonarqube-provision";
    src = ./impl/provision-admin.sh;
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
    ];
  };
  stopBackend = mkCommand {
    name = "dotfiles-sonarqube-stop";
    src = ./impl/stop-backend.sh;
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      util-linux
      systemd
    ];
    vars = {
      serverUnit = lib.escapeShellArg serverUnit;
      # front は app と DB を Requires するため app の停止で連鎖して止まる
      stopUnits = lib.escapeShellArgs (
        [
          lifecycle.startUnit
          provisionUnit
        ]
        ++ backend.units
      );
    };
  };
in
{
  options.dotfiles.capabilities.code-quality.sonarqube.lifecycle = {
    startUnit = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "sonarqube.target";
      description = "operator が `systemctl start` する起動の入口。API の UP と admin credential の検証まで待つ";
    };
    stopUnit = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "sonarqube-stop.service";
      description = "operator が `systemctl start` する停止の入口。scan と Compute Engine の処理中は拒否する";
    };
    scanLockFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/run/sonarqube-lifecycle/scan.lock";
      description = "scanner wrapper が共有で、停止の入口が排他で取る flock の file";
    };
  };

  config = lib.mkIf enabled {
    dotfiles.platform.cli.commands.sonarqube-provision = provisionAdmin;

    systemd.tmpfiles.rules = [
      "d ${dirOf lifecycle.scanLockFile} 0755 root root -"
      "f ${lifecycle.scanLockFile} 0644 root root -"
    ];

    systemd.targets.${lib.removeSuffix ".target" lifecycle.startUnit} = {
      description = "SonarQube backend started by its operator";
      requires = [
        serverUnit
        provisionUnit
        frontUnit
      ];
      after = [
        serverUnit
        provisionUnit
        frontUnit
      ];
    };

    # 起動の入口と稼働中の secret 差替えで同じ検証を通す。単独起動では app を引かない
    systemd.services.${lib.removeSuffix ".service" provisionUnit} = {
      description = "SonarQube admin credential provisioning";
      after = [ serverUnit ];
      requisite = [ serverUnit ];
      partOf = [ serverUnit ];
      serviceConfig = sandbox // {
        Type = "oneshot";
        RemainAfterExit = true;
        User = config.dotfiles.workstation.username;
        LoadCredential = [ adminCredential ];
        Environment = credentialEnvironment;
        ExecStart = lib.getExe provisionAdmin;
        TimeoutStartSec = "6min";
        MemoryMax = "128M";
        TasksMax = 32;
      };
    };

    # 停止の入口が排他の lock を持つ間は app と DB の起動を拒否し、判定と停止の間に起動を割り込ませない
    systemd.services.${lib.removeSuffix ".service" startGuardUnit} = {
      description = "Refuse SonarQube starts while its guarded stop runs";
      serviceConfig = sandbox // {
        Type = "oneshot";
        MemoryMax = "32M";
        TasksMax = 8;
      };
      script = ''
        if ! ${pkgs.util-linux}/bin/flock --shared --nonblock ${lib.escapeShellArg lifecycle.scanLockFile} ${pkgs.coreutils}/bin/true; then
          echo "Refusing to start SonarQube while ${lifecycle.stopUnit} holds the analysis lock; start it after the stop finishes" >&2
          exit 1
        fi
      '';
    };
    systemd.services.docker-sonarqube = {
      requires = [ startGuardUnit ];
      after = [ startGuardUnit ];
    };
    systemd.services.docker-sonarqube-db = {
      requires = [ startGuardUnit ];
      after = [ startGuardUnit ];
    };

    # 依存を持たない oneshot。停止を自身の job から要求するため順序の依存は deadlock になり不可
    systemd.services.${lib.removeSuffix ".service" lifecycle.stopUnit} = {
      description = "Guarded operator stop of the SonarQube backend";
      serviceConfig = sandbox // {
        Type = "oneshot";
        LoadCredential = [ adminCredential ];
        Environment = credentialEnvironment ++ [ "SONARQUBE_LIFECYCLE_LOCK=${lifecycle.scanLockFile}" ];
        ExecStart = lib.getExe stopBackend;
        TimeoutStartSec = "5min";
        MemoryMax = "128M";
        TasksMax = 32;
      };
    };
  };
}
