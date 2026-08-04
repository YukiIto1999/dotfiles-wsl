{
  config,
  lib,
  pkgs,
  mkCommand,
  ...
}:

let
  cfg = config.my;

  # 検証対象は宣言から導く。別の roster を持つと宣言と乖離する
  declaredUnits = builtins.attrNames (
    lib.filterAttrs (_: unit: unit.wantedBy or [ ] != [ ]) config.systemd.services
  );

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
    };
  };
in
{
  config.my.commands = { inherit doctor; };
}
