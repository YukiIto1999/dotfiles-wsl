{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  doctor = lib.getExe hostConfig.dotfiles.commands.doctor;

  # doctor が最低限触れねばならない常駐 service。front と container と gateway は
  # どれが落ちても agent が道具を失うので、被覆から漏れてはならない
  required =
    map (front: front.service) (builtins.attrValues hostConfig.dotfiles.mcp.fronts)
    ++ [ hostConfig.dotfiles.mcp.gateway.service ]
    ++ map (name: "docker-${name}") (
      builtins.attrNames hostConfig.virtualisation.oci-containers.containers
    );

  expectedProbes = builtins.fromJSON (builtins.readFile ./fixtures/probes.json);
  probes = lib.mapAttrsToList (
    target: contract: "${target}_${contract.probe.tool}"
  ) hostConfig.dotfiles.mcp.targets;
in
{
  # 検証対象を別の roster から取らず、宣言した unit から導くこと。
  # 導出が空集合でも doctor は緑を返すので、被覆を検査側で要求する
  doctor-coverage =
    assert expectedProbes != [ ];
    assert probes == expectedProbes;
    pkgs.runCommandLocal "check-doctor-coverage"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.gnused
        ];
      }
      ''
        set -euo pipefail

        units=$(sed -n "s/^units='\(.*\)'$/\1/p" ${doctor} | tr ' ' '\n')
        probed=$(sed -n "s/^probes='\(.*\)'$/\1/p" ${doctor} | tr ' ' '\n')

        for name in ${lib.escapeShellArgs required}; do
          printf '%s\n' "$units" | grep -qx "$name" || {
            echo "doctor does not check $name" >&2
            exit 1
          }
        done

        for name in ${lib.escapeShellArgs probes}; do
          printf '%s\n' "$probed" | grep -qx "$name" || {
            echo "doctor does not probe target $name" >&2
            exit 1
          }
        done

        grep -Fq '${hostConfig.dotfiles.mcp.gateway.url}' ${doctor}
        touch $out
      '';
}
