# 切替前に起動した agent session のための互換 command。
# 削除条件: 旧 runtime の `supervise.py` という名前の process が一つも無いこと（dotfiles-doctor が判定する）。
#
# 旧 session の停止 hook は毎回 /run/current-system/sw/bin/dotfiles-agent-gate を解決し、無いと停止を拒む。
# 旧 policy が指示する dotfiles-agent-verify、dotfiles-workload-run、dotfiles-capped-run は、
# 自分の option を読み飛ばして `--` の後の command をそのまま実行する。
{ pkgs, ... }:

let
  passThrough =
    name:
    pkgs.writeShellApplication {
      inherit name;
      text = ''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = -- ]; then
            shift
            [ "$#" -gt 0 ] || break
            exec "$@"
          fi
          shift
        done
        echo "usage: ${name} [OPTION...] -- COMMAND [ARG...]" >&2
        exit 64
      '';
    };
in
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "dotfiles-agent-gate";
      text = ''
        cat >/dev/null || true
        exit 0
      '';
    })
    (passThrough "dotfiles-agent-verify")
    (passThrough "dotfiles-workload-run")
    (passThrough "dotfiles-capped-run")
  ];
}
