set -euo pipefail

die() {
  printf 'dotfiles-project-run: %s\n' "$1" >&2
  exit 70
}

usage() {
  printf '%s\n' 'usage: dotfiles-project-run [--attr NAME] -- ABSOLUTE-EXECUTABLE [ARG...]' >&2
  exit 2
}

attr=default
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attr)
      [ "$#" -ge 2 ] || usage
      attr=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
done
[ "$#" -ge 1 ] || usage

executable=$1
shift
case "$attr" in
  '' | -* | *[!A-Za-z0-9._-]*) die "invalid devShell name: $attr" ;;
esac
# env が先頭の NAME=VALUE を代入として読むため、= を含む path は command として渡せない。
case "$executable" in
  /*=*) die "executable path contains '=': $executable" ;;
  /*) ;;
  *) die "executable is not an absolute path: $executable" ;;
esac
[ -f "$executable" ] && [ -x "$executable" ] || die "executable is not runnable: $executable"

# 信頼は direnv の承認(未承認 1、拒否 2)をそのまま使う。許可済み(0)だけを通し、
# direnv exec が拒否 2 で基礎環境を返す経路には載せない。
approval=$(@direnvCommand@ status --json 2>/dev/null) || die 'cannot read the direnv approval state'
rc_path=$(jq -er '.state.foundRC.path // empty' <<<"$approval") \
  || die 'no .envrc found for this directory; review the project, then run direnv allow'
rc_allowed=$(jq -er '.state.foundRC.allowed' <<<"$approval") \
  || die 'cannot read the approval state of the project .envrc'
[ "${rc_path##*/}" = .envrc ] || die "not an .envrc: $rc_path"
[ "$rc_allowed" = 0 ] || die "the project environment is not approved ($rc_path); review it, then run direnv allow"
project_root=${rc_path%/*}
case "$project_root" in
  /*) ;;
  *) die "project root is not absolute: $project_root" ;;
esac
# flake 参照として再解釈される文字は、承認した directory とは別の対象を指し得る。
case "$project_root" in
  *[\#\?%]*) die "project root has characters a flake reference would reinterpret: $project_root" ;;
esac

# nix develop は TMPDIR 等を常に新しい nix-shell directory へ書き換える。呼び出し側が指定した
# 状態(未指定、空文字列、値)を、内側の command が見る環境へ戻す。
restore_unset=()
restore_set=()
for name in TMPDIR TMP TEMP TEMPDIR; do
  if [ "${!name+x}" = x ]; then
    restore_set+=("$name=${!name}")
  else
    restore_unset+=(-u "$name")
  fi
done

scope=()
cgroup_path=$(<@cgroupFile@) || die 'cannot read the resource scope'
# 既存 agent のより狭い上限を外す再配置は不可
case "$cgroup_path" in
  0::/user.slice | 0::/user.slice/*) ;;
  0::/*) scope=(@systemdRunCommand@ --user --scope --collect --quiet --slice=app.slice --) ;;
  *) die 'a unified cgroup hierarchy is required for the resource scope' ;;
esac

# --no-update-lock-file へ --no-write-lock-file を足すと更新が要る lock を警告だけで通すため追加は不可
# 実行ファイルは絶対 path で渡し、devShell の PATH の後ろにある host の PATH を引かない。
exec "${scope[@]}" @nixCommand@ develop --no-update-lock-file "$project_root#$attr" \
  --command @envCommand@ "${restore_unset[@]}" "${restore_set[@]}" "$executable" "$@"
