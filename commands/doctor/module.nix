{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;

  agentTable = lib.mapAttrsToList (id: client: {
    inherit id;
    inherit (client) binary versionArgs;
  }) cfg.agents.clients;

  artifactTable = lib.mapAttrsToList (id: artifact: {
    inherit id;
    source = toString artifact.source;
    destination = artifact.deployedAt;
  }) (lib.filterAttrs (_: artifact: artifact.deployedAt != null) cfg.artifacts);

  secretTable = lib.mapAttrsToList (id: secret: {
    inherit id;
    inherit (secret) path mode;
    owner = if secret.owner == null then "root" else secret.owner;
    group = if secret.group == null then "root" else secret.group;
  }) config.sops.secrets;

  homeManagerUnit = "home-manager-${cfg.host.username}.service";

  serviceNames = lib.unique (
    [
      homeManagerUnit
      cfg.telemetry.service
      cfg.mcp.gateway.service
    ]
    ++ lib.concatMap (service: service.units) (builtins.attrValues cfg.containers.services)
    ++ map (front: front.service) (builtins.attrValues cfg.mcp.fronts)
  );

  serviceTable = map (unit: {
    inherit unit;
    role = if unit == homeManagerUnit then "home-manager" else "service";
  }) serviceNames;

  maintenanceTimerNames = builtins.filter (
    name:
    let
      timer = config.systemd.timers.${name};
      serviceUnit = timer.timerConfig.Unit or "${name}.service";
      serviceName = lib.removeSuffix ".service" serviceUnit;
      serviceDescription = config.systemd.services.${serviceName}.description or "";
    in
    builtins.elem name [
      "nix-gc"
      "fstrim"
      "docker-buildkit-gc"
    ]
    || (lib.hasPrefix "dotfiles-agent-" name && lib.hasSuffix "-gc" name)
    || (lib.hasSuffix "reaper" name && lib.hasInfix "worktree" (lib.toLower serviceDescription))
  ) (builtins.attrNames config.systemd.timers);

  maintenanceTable = map (
    name:
    let
      timer = config.systemd.timers.${name};
    in
    {
      timer = "${name}.timer";
      service = timer.timerConfig.Unit or "${name}.service";
    }
  ) maintenanceTimerNames;

  managedRootTable = [
    "${cfg.host.homeDir}/.cache/dotfiles-wsl/builds"
    "${cfg.host.homeDir}/.cache/dotfiles-wsl/shared"
    "${cfg.host.homeDir}/.cache/dotfiles-wsl/sessions"
    "${cfg.host.homeDir}/.local/state/dotfiles-wsl/agent-resources"
  ];

  containerTable = lib.concatMap (
    application:
    map (image: {
      inherit application;
      inherit (image) container image;
    }) (builtins.attrValues cfg.containers.services.${application}.images)
  ) cfg.containers.enabled;

  healthTable = map (
    application:
    let
      service = cfg.containers.services.${application};
      probe = service.health;
    in
    {
      inherit application;
      url = "${service.endpoints.${probe.endpoint}.url}${probe.path}";
      inherit (probe) method timeout;
    }
  ) cfg.containers.enabled;

  mcpTable = lib.mapAttrsToList (id: target: {
    inherit id;
    inherit (target) probe;
  }) cfg.mcp.targets;

  doctor = import ./package.nix {
    inherit pkgs lib;
    tables = {
      inherit
        agentTable
        artifactTable
        secretTable
        serviceTable
        maintenanceTable
        managedRootTable
        containerTable
        healthTable
        mcpTable
        ;
      gatewayUrl = cfg.mcp.gateway.url;
    };
  };
in
{
  config.dotfiles.commands = { inherit doctor; };
}
