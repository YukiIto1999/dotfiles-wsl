{
  lib,
  pkgs,
  runner,
  lifecycle,
}:

{
  name,
  description,
  worker,
  onCalendar,
  executionDependencies,
  executables,
}:

let
  executionLimitSeconds = 6 * 60 * 60;
  drainSeconds = 60;
  stopMarginSeconds = 60;
  holds = [ worker ] ++ executionDependencies;
  declare = option: path: "--executable ${lib.escapeShellArg "${option}=${toString path}"}";
  executableOptions = lib.concatStringsSep " " (lib.mapAttrsToList declare executables);
  entry = pkgs.writeShellApplication {
    name = "${name}-job";
    text = ''
      exec ${lib.getExe runner} \
        --name ${lib.escapeShellArg name} \
        --limit-seconds ${toString executionLimitSeconds} \
        --drain-seconds ${toString drainSeconds} \
        --supervise ${lib.getExe lifecycle.supervise} \
        --protect ${lib.getExe lifecycle.protect} \
        ${lib.concatMapStringsSep " " (path: "--hold ${lib.escapeShellArg (toString path)}") holds} \
        ${executableOptions} \
        -- ${lib.getExe worker} "$@"
    '';
  };
in
{
  command = lifecycle.mkWrapper {
    client = name;
    binary = name;
    targetExecutable = lib.getExe entry;
    executionDependencies = map toString (
      [
        entry
        worker
      ]
      ++ executionDependencies
    );
  };

  units = {
    services.${name} = {
      Unit.Description = description;
      Service = {
        Type = "oneshot";
        Slice = "agents.slice";
        ExecStart = lib.getExe entry;
        KillMode = "control-group";
        TimeoutStartSec = executionLimitSeconds + drainSeconds + stopMarginSeconds;
        TimeoutStopSec = drainSeconds + stopMarginSeconds;
        Environment = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" ];
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

  observation = {
    kind = "systemd-timer";
    manager = "user";
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
}
