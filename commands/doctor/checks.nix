{
  pkgs,
  lib,
  hostConfig,
  ...
}:

{
  # 検証対象を別の roster から取らず、宣言した unit から導くこと
  doctor-entrypoint =
    let
      doctor = lib.getExe hostConfig.my.commands.doctor;
    in
    pkgs.runCommandLocal "check-doctor-entrypoint" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
      set -euo pipefail
      grep -q 'systemctl show' ${doctor}
      grep -q 'initialize' ${doctor}
      grep -Fq '${hostConfig.my.contract.gateway.endpoints.default.url}' ${doctor}
      touch $out
    '';
}
