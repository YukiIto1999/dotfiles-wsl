{
  config,
  options,
  lib,
  pkgs,
  self,
  mkCommand,
  ...
}:

let
  cfg = config.my;

  # 検証対象は宣言から導く。別の roster を持つと宣言と乖離する
  # 常駐しない oneshot は完了後に inactive になる。この repo が宣言し、かつ
  # 常駐する service だけを active であるべき対象にする
  declaredHere = lib.unique (
    lib.concatMap (
      definition:
      lib.optionals (lib.hasPrefix (toString self) (toString definition.file)) (
        builtins.attrNames definition.value
      )
    ) options.systemd.services.definitionsWithLocations
  );

  declaredUnits = builtins.filter (
    name:
    let
      unit = config.systemd.services.${name};
    in
    unit.wantedBy or [ ] != [ ] && (unit.serviceConfig.Type or "simple") != "oneshot"
  ) declaredHere;

  doctor = mkCommand {
    name = "dotfiles-doctor";
    src = ./impl/doctor.sh;
    runtimeInputs = with pkgs; [
      coreutils
      curl
      systemd
    ];
    vars = {
      declaredUnits = lib.escapeShellArg (lib.concatStringsSep " " declaredUnits);
      gatewayUrl = lib.escapeShellArg cfg.contract.gateway.endpoints.default.url;
      mcpTargets = lib.escapeShellArg (lib.concatStringsSep " " (builtins.attrNames cfg.mcp.targets));
    };
  };
in
{
  config.my.commands = { inherit doctor; };
}
