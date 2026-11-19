#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: dotfiles-verification-build INSTALLABLE...\n' >&2
  exit 64
}

[ "$#" -ge 1 ] || usage

roots_directory=dotfiles-verification-roots
link_prefix=
unheld_reason=

# 成功した出力を保持できるかを決める
# 保持の追加は store の空きが nix の自動 GC の開始量 min-free 以上のときに限る。下回る間は GC が空きを戻す途中で、保持を足すと戻らないため
# これは開始時の空きだけの門で、空きの予約ではない。build 自身や他の writer が build 中に min-free を下回らせても、公開する link は止まらない
# その場合の保持は、置き換える一世代（前の世代の専有分は置き換えで解放される）に限られ、増え続けない
# 保持先は所有 checkout の git-dir の中。作業木には何も置かず、checkout を消せば root も消えて、保持は checkout の数で抑えられる
# 所有 checkout は DOTFILES_VERIFICATION_OWNER の directory、無ければ呼び出した directory。dotfiles-rebuild の隔離 clone が元の checkout を名指す唯一の入口
# clone 自身の git-dir へ置く方式は、clone の削除で root の導線だけが残り、元の checkout の root も更新できないため不可。所有 checkout を読めなければ clone の git-dir へ退かず保持しない
# 出力 link_prefix: 保持する場合の nix build --out-link の prefix。保持しなければ空
# 出力 unheld_reason: 保持しない理由
decide_roots() {
  local owner git_dir min_free store_dir stats blocks block_size available

  owner=${DOTFILES_VERIFICATION_OWNER:-$PWD}
  git_dir=$(git -C "$owner" rev-parse --absolute-git-dir 2>/dev/null) || {
    unheld_reason="no readable git checkout at $owner"
    return 0
  }
  min_free=$(nix config show min-free 2>/dev/null) || min_free=
  if ! [[ $min_free =~ ^[0-9]{1,18}$ ]]; then
    unheld_reason='nix min-free is not readable'
    return 0
  fi
  store_dir=${NIX_STORE_DIR:-/nix/store}
  stats=$(stat -f -c '%a %S' -- "$store_dir" 2>/dev/null) || {
    unheld_reason="the free space of $store_dir is not readable"
    return 0
  }
  read -r blocks block_size <<<"$stats"
  available=$((blocks * block_size))
  if [ "$available" -lt "$min_free" ]; then
    unheld_reason="free space $((available >> 30)) GiB is below nix min-free $((10#$min_free >> 30)) GiB"
    return 0
  fi
  mkdir -p -- "$git_dir/$roots_directory" 2>/dev/null || {
    unheld_reason="cannot create $git_dir/$roots_directory"
    return 0
  }
  link_prefix=$git_dir/$roots_directory/outputs
}

decide_roots
# 保持の有無で検査の合否も引数の順も変えない。installable の位置 N が link の名前 outputs-N を決める（先頭は suffix なし）
# 前の link の削除と一時 link からの付け替えを自前で行う方式の不採用: 失敗した build が前の成功の root を消すため。
# nix build は全 installable の成功後にだけ link を原子的に置き換えるので、失敗や中断では前の root がそのまま残る
if [ -n "$link_prefix" ]; then
  printf 'verification roots: holding the outputs at %s[-N]\n' "$link_prefix" >&2
  exec nix build --no-write-lock-file -L --out-link "$link_prefix" "$@"
fi
printf 'verification roots: the outputs are not held (%s)\n' "$unheld_reason" >&2
exec nix build --no-write-lock-file -L --no-link "$@"
