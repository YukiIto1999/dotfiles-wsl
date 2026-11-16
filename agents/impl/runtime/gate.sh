#!/usr/bin/env bash
set -euo pipefail

# 検証入口を通していない木で agent が仕事を終えられないようにする門。
#
# dotfiles-agent-verify は成功した走行の指紋を控えるが、その控えを読む者がいなかった。
# 読む者をここに置く。agent が編集した repository ごとに、検証入口が「いまの木」に対して
# 通っているかを stop の時点で問い、通っていなければ理由と入口の綴りを返して止める。

usage() {
  cat >&2 <<'USAGE'
usage: dotfiles-agent-gate <command> [options]

  slot [--repo DIR]                     その project の検証の実行枠 file を安全に確保して答える。同じ project の T1 は flock で一度に一つ走る
  record --pending TOKEN [--repo DIR] [--command TEXT]
                                        DIR が根で TEXT が検証入口の綴りなら、公開しない仮の控えを作り、その木の照合値を出す
  publish --pending TOKEN --witness DIGEST [--repo DIR]
                                        木が照合値のままなら仮の控えを木の控えとして公開する。deadline の下で呼ぶ
  discard --pending TOKEN             その走行の仮の控えと公開した控え、一時fileだけを捨てる
  arm --session ID [--path PATH]        その session が編集した repository を控える
  check [--repo DIR] [--session ID]     未検証なら理由を出して 1 で終わる
  waive --reason TEXT [--repo DIR]      理由を残していまの木を一度だけ通す
  entry [--repo DIR] [--policy FILE]      repository が登録する検証入口の綴りを評価器を起動せずに答える
  candidates [--repo DIR]               予算が読めない間に、検証入口になり得る綴りを評価せずに一行ずつ答える
  budget [--repo DIR] [--policy FILE]     その repository の T1 の時間予算を秒で答える。宣言が無い、または不正なら理由を出して 1 で終わる
  snapshot [--repo DIR]                 一度読んだ静的な検証宣言を JSON で答える。entry、budget、push-declaration の --policy に渡す
  push-declaration [--repo DIR] [--policy FILE]
                                        T2 の入口があるのに予算を読めない宣言を、push で拒否されると stderr で知らせる。常に 0 で終わる
  hook <arm|observe|stop>               client の hook から stdin の JSON で起こす
USAGE
  exit 64
}

cache_root="$HOME/@cacheRootRelative@"
verification_root="$cache_root/verification"
sessions_root="$verification_root/sessions"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

repo_top_of() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

project_id_of() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  common=$(realpath -e -- "$common") || return 1
  printf '%s' "$common" | sha256sum | cut -d ' ' -f 1
}

source_fingerprint() {
  local repo=$1 head path
  head=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null || printf 'none')
  {
    printf 'dotfiles-agent-gate-v3\0head\0%s\0tracked\0' "$head"
    # porcelain の git diff は --no-optional-locks でも index を書き直して index.lock を取り hook の SIGKILL で lock を残すため不可
    git -C "$repo" -c color.ui=false diff-index -p --binary --full-index --no-ext-diff --no-textconv HEAD --
    printf '\0untracked\0'
    while IFS= read -r -d '' path; do
      printf 'path\0%s\0' "$path"
      if [ -L "$repo/$path" ]; then
        printf 'symlink\0'
        readlink --zero -- "$repo/$path"
      elif [ -f "$repo/$path" ]; then
        printf 'regular\0'
        sha256sum <"$repo/$path"
      else
        printf 'other\0'
      fi
    done < <(git -C "$repo" ls-files --others --exclude-standard -z)
  } | sha256sum | cut -d ' ' -f 1
}

# 検証の走行の前後で木が触られていないことを示す照合値。source_fingerprint が「どの木か」を名指すのに対し、
# こちらは HEAD と index、追跡 file の内容と lstat、gitlink の中身、未追跡 file の内容と lstat を採り、
# 読む前後で食い違えば採取自体を失敗させる。同じ内容への書き戻しも mtime と ctime で区別する。
# 採れない木には証跡を作らない。汚れた gitlink、特殊 file、採取中の変更がそれに当たる。
# 一時 file は呼び出し側が用意した木の外の witness_scratch へ置く。
witness_scratch=

write_tracked_witness() {
  local repository=$1 tracked=$2 namespace=$3
  local record index_fields index_mode path absolute semantic_path
  local index_oid index_stage metadata digest offset batch validation_guard
  local -a paths=() regulars=()
  local -A metadata_before=() guards_before=() hashes=()
  local -A metadata_after=() guards_after=()

  batch=$(mktemp -d "$witness_scratch/.tracked-batch.XXXXXXXX") || return 1
  while IFS= read -r -d '' record; do
    [[ $record == *$'\t'* ]] || return 1
    index_fields=${record%%$'\t'*}
    index_mode=${index_fields%% *}
    index_stage=${index_fields##* }
    [ "$index_stage" = 0 ] || return 1
    path=${record#*$'\t'}
    absolute=$repository/$path
    if [ ! -e "$absolute" ] && [ ! -L "$absolute" ]; then
      [ "$index_mode" != 160000 ] || return 1
      continue
    fi
    paths+=("$absolute")
    if [ "$index_mode" = 160000 ]; then
      [ -d "$absolute" ] && [ ! -L "$absolute" ] || return 1
    elif [ -L "$absolute" ]; then
      continue
    elif [ -f "$absolute" ]; then
      regulars+=("$absolute")
    else
      return 1
    fi
  done <"$tracked"

  : >"$batch/before"
  for ((offset = 0; offset < ${#paths[@]}; offset += 128)); do
    stat --printf '%n\0%f:%u:%g:%h:%s\0%d:%i:%f:%u:%g:%h:%s:%y:%z\0' \
      -- "${paths[@]:offset:128}" >>"$batch/before" 2>/dev/null || return 1
  done
  while IFS= read -r -d '' absolute \
    && IFS= read -r -d '' metadata \
    && IFS= read -r -d '' record; do
    metadata_before["$absolute"]=$metadata
    guards_before["$absolute"]=$record
  done <"$batch/before"

  : >"$batch/hashes"
  for ((offset = 0; offset < ${#regulars[@]}; offset += 128)); do
    sha256sum --zero -- "${regulars[@]:offset:128}" >>"$batch/hashes" || return 1
  done
  while IFS= read -r -d '' record; do
    digest=${record:0:64}
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
    hashes["${record:66}"]=$digest
  done <"$batch/hashes"

  while IFS= read -r -d '' record; do
    index_fields=${record%%$'\t'*}
    index_mode=${index_fields%% *}
    index_oid=${index_fields#* }
    index_oid=${index_oid%% *}
    path=${record#*$'\t'}
    absolute=$repository/$path
    semantic_path=$namespace$path
    printf 'index\0%s\0path\0%s\0' "$index_fields" "$semantic_path"
    if [ ! -e "$absolute" ] && [ ! -L "$absolute" ]; then
      [ -z "${metadata_before["$absolute"]-}" ] || return 1
      printf 'missing\0'
      continue
    fi
    metadata=${metadata_before["$absolute"]-}
    [ -n "$metadata" ] || return 1
    validation_guard=${guards_before["$absolute"]}
    # gitlink の directory 自体は、中の配置で変わる link 数と大きさ、時刻を照合値へ入れない
    if [ "$index_mode" = 160000 ]; then
      metadata=${metadata%:*}
      metadata=${metadata%:*}
      record=${validation_guard#*:}
      validation_guard="${validation_guard%%:*}:${record%%:*}:$metadata"
    fi
    printf 'lstat\0%s\0guard\0%s\0' "$metadata" "$validation_guard"
    if [ "$index_mode" = 160000 ]; then
      [ -d "$absolute" ] && [ ! -L "$absolute" ] || return 1
      write_clean_gitlink "$absolute" "$index_oid" "$semantic_path/" || return 1
    elif [ -L "$absolute" ]; then
      printf 'symlink\0'
      readlink --zero -- "$absolute" || return 1
    elif [ -f "$absolute" ]; then
      digest=${hashes["$absolute"]-}
      [ -n "$digest" ] || return 1
      printf 'regular\0%s  -\n' "$digest"
    else
      return 1
    fi
  done <"$tracked"

  : >"$batch/after"
  for ((offset = 0; offset < ${#paths[@]}; offset += 128)); do
    stat --printf '%n\0%f:%u:%g:%h:%s\0%d:%i:%f:%u:%g:%h:%s:%y:%z\0' \
      -- "${paths[@]:offset:128}" >>"$batch/after" 2>/dev/null || return 1
  done
  while IFS= read -r -d '' absolute \
    && IFS= read -r -d '' metadata \
    && IFS= read -r -d '' record; do
    metadata_after["$absolute"]=$metadata
    guards_after["$absolute"]=$record
  done <"$batch/after"
  for absolute in "${paths[@]}"; do
    [ "${metadata_after["$absolute"]-}" = "${metadata_before["$absolute"]}" ] || return 1
    [ "${guards_after["$absolute"]-}" = "${guards_before["$absolute"]}" ] || return 1
  done
  while IFS= read -r -d '' record; do
    path=${record#*$'\t'}
    absolute=$repository/$path
    if [ -z "${metadata_before["$absolute"]-}" ]; then
      [ ! -e "$absolute" ] && [ ! -L "$absolute" ] || return 1
    fi
  done <"$tracked"
}

validate_index_flags() {
  local flags=$1 record
  while IFS= read -r -d '' record; do
    [[ $record == 'H '* ]] || return 1
  done <"$flags"
}

# gitlink は HEAD が index の記録と一致し、中の木が一切汚れていないときだけ中身まで照合する。
# assume-unchanged や skip-worktree の印は git の変更検出を偽れるため受け付けない。
write_clean_gitlink() {
  local absolute=$1 expected_head=$2 namespace=$3
  local canonical top head_before head_after
  local index_before index_after flags_before flags_after status_before status_after

  [[ $expected_head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 1
  canonical=$(realpath -e -- "$absolute") || return 1
  top=$(git -C "$absolute" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(realpath -e -- "$top") || return 1
  [ "$top" = "$canonical" ] || return 1
  head_before=$(git -C "$absolute" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  [ "$head_before" = "$expected_head" ] || return 1

  index_before=$(mktemp "$witness_scratch/.gitlink-index-before.XXXXXXXX") || return 1
  index_after=$(mktemp "$witness_scratch/.gitlink-index-after.XXXXXXXX") || return 1
  flags_before=$(mktemp "$witness_scratch/.gitlink-flags-before.XXXXXXXX") || return 1
  flags_after=$(mktemp "$witness_scratch/.gitlink-flags-after.XXXXXXXX") || return 1
  status_before=$(mktemp "$witness_scratch/.gitlink-status-before.XXXXXXXX") || return 1
  status_after=$(mktemp "$witness_scratch/.gitlink-status-after.XXXXXXXX") || return 1

  git -C "$absolute" ls-files --stage -z >"$index_before" || return 1
  git -C "$absolute" ls-files -v -z >"$flags_before" || return 1
  validate_index_flags "$flags_before" || return 1
  git --no-optional-locks -C "$absolute" status --porcelain=v1 --untracked-files=all \
    --ignore-submodules=all >"$status_before" 2>/dev/null || return 1
  [ ! -s "$status_before" ] || return 1

  printf 'gitlink\0head\0%s\0flags\0' "$head_before"
  cat "$flags_before" || return 1
  printf '\0tracked\0'
  write_tracked_witness "$absolute" "$index_before" "$namespace" || return 1

  git -C "$absolute" ls-files --stage -z >"$index_after" || return 1
  git -C "$absolute" ls-files -v -z >"$flags_after" || return 1
  cmp -s -- "$index_before" "$index_after" || return 1
  cmp -s -- "$flags_before" "$flags_after" || return 1
  validate_index_flags "$flags_after" || return 1
  git --no-optional-locks -C "$absolute" status --porcelain=v1 --untracked-files=all \
    --ignore-submodules=all >"$status_after" 2>/dev/null || return 1
  [ ! -s "$status_after" ] || return 1
  head_after=$(git -C "$absolute" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  [ "$head_after" = "$head_before" ] || return 1
}

write_untracked_guard() {
  local repo=$1 list=$2 path
  while IFS= read -r -d '' path; do
    printf 'path\0%s\0' "$path"
    stat --printf '%d:%i:%f:%u:%g:%h:%s:%y:%z\0' -- "$repo/$path" || return 1
  done <"$list"
}

write_untracked_content() {
  local repo=$1 list=$2 path link_target mode
  while IFS= read -r -d '' path; do
    printf 'path\0%s\0' "$path"
    if [ -L "$repo/$path" ]; then
      link_target=$(readlink -- "$repo/$path") || return 1
      printf 'symlink\0%s\0' "$link_target"
    elif [ -f "$repo/$path" ]; then
      mode=$(stat -c %a "$repo/$path") || return 1
      printf 'regular\0%s\0' "$mode"
      sha256sum -- "$repo/$path" || return 1
    else
      return 1
    fi
  done <"$list"
}

# 照合値を出して 0 で返る。木が採取の間に変わった、または採れない種類を含むときは 1 で返る。
source_witness() {
  local repo=$1 dir=$witness_scratch head head_after
  head=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$repo" ls-files --stage -z >"$dir/tracked" || return 1
  write_tracked_witness "$repo" "$dir/tracked" "" >"$dir/tracked-witness" || return 1
  # porcelain の git diff は --no-optional-locks でも index を書き直して index.lock を取り hook の SIGKILL で lock を残すため不可
  git -C "$repo" -c color.ui=false diff-index -p \
    --binary --full-index --no-ext-diff --no-textconv HEAD -- >"$dir/tracked-diff" || return 1
  git -C "$repo" ls-files --others --exclude-standard -z >"$dir/untracked" || return 1
  write_untracked_guard "$repo" "$dir/untracked" >"$dir/untracked-guard" || return 1
  write_untracked_content "$repo" "$dir/untracked" >"$dir/untracked-content" || return 1

  git -C "$repo" ls-files --stage -z >"$dir/tracked-after" || return 1
  cmp -s -- "$dir/tracked" "$dir/tracked-after" || return 1
  head_after=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) || return 1
  [ "$head_after" = "$head" ] || return 1
  git -C "$repo" ls-files --others --exclude-standard -z >"$dir/untracked-after" || return 1
  cmp -s -- "$dir/untracked" "$dir/untracked-after" || return 1
  write_untracked_guard "$repo" "$dir/untracked-after" >"$dir/untracked-guard-after" || return 1
  cmp -s -- "$dir/untracked-guard" "$dir/untracked-guard-after" || return 1
  {
    printf 'dotfiles-agent-gate-witness-v1\0head\0%s\0tracked-diff\0' "$head"
    cat "$dir/tracked-diff" || return 1
    printf '\0tracked\0'
    cat "$dir/tracked-witness" || return 1
    printf '\0untracked-guard\0'
    cat "$dir/untracked-guard" || return 1
    printf '\0untracked-content\0'
    cat "$dir/untracked-content" || return 1
  } | sha256sum | cut -d ' ' -f 1
}

# その repository が宣言する T1 の検証入口。宣言が無ければ空を返し、門は何も要求しない。
# 段の名前と宣言の置き場の解決は git の pre-push と共有する。
entry_of() {
  "@verificationEntry@" --repo "$1" "${policy_args[@]}" verify
}

declared_entry_of() {
  local entry policy
  policy=$(snapshot_of "$1") || return $?
  entry=$("@verificationEntry@" --repo "$1" --policy /dev/stdin verify <<<"$policy") || return $?
  if [ -n "$entry" ]; then
    "@verificationEntry@" --repo "$1" --policy /dev/stdin --budget verify <<<"$policy" >/dev/null || return $?
  fi
  printf '%s' "$entry"
}

candidates_of() {
  "@verificationEntry@" --repo "$1" --candidates verify
}

budget_of() {
  "@verificationEntry@" --repo "$1" "${policy_args[@]}" --budget verify
}

snapshot_of() {
  "@verificationEntry@" --repo "$1" --snapshot verify
}

# push の時に初めて拒否される T2 の宣言の欠けを作業の終わりに知らせる
# T2 の予算は push の時だけ要るため push と関係の無い T1 を止める失敗扱いは不可
command_push_declaration() {
  local top entry problem
  top=$(repo_top_of "$1") || return 0
  if ! entry=$("@verificationEntry@" --repo "$top" "${policy_args[@]}" verify-push 2>&1); then
    printf 'verify: T2 の入口を解決できないため、push は pre-push に拒否される\n%s\n' "$entry" >&2
    return 0
  fi
  [ -n "$entry" ] || return 0
  if ! problem=$("@verificationEntry@" --repo "$top" "${policy_args[@]}" --budget verify-push 2>&1 >/dev/null); then
    printf 'verify: T2 の入口 %s の時間予算を読めないため、push は pre-push に拒否される\n%s\n' "$entry" "$problem" >&2
  fi
}

state_dir_of() {
  local repo=$1 id
  id=$(project_id_of "$repo") || return 1
  printf '%s/%s' "$verification_root" "$id"
}

# 宣言した入口を repository の根で通した走行だけを控える。部分的な検査や下の directory での
# 走行が通っても、入口がこの木で通ったことにはならない。
receipt_scratch=

receipt_token_is_valid() {
  [[ $1 =~ ^[0-9]{16}\.[0-9]+$ ]]
}

producer_start_time() {
  local process_stat
  local -a fields
  process_stat=$(<"/proc/$1/stat") 2>/dev/null || return 1
  read -r -a fields <<<"${process_stat##*) }"
  [[ ${fields[19]-} =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${fields[19]}"
}

verified_receipt_token=
verified_receipt_exists() {
  local candidate token producer boot_id start_time current_start_time current_boot_id
  local -a record
  IFS= read -r current_boot_id </proc/sys/kernel/random/boot_id || return 1
  verified_receipt_token=
  project_state_is_private "$1" || return 1
  for candidate in "$1/$2".*.verified; do
    state_file_is_private "$candidate" || continue
    mapfile record <"$candidate"
    [ "${#record[@]}" -eq 7 ] || continue
    [ "${record[0]}" = $'version=4\n' ] || continue
    [ "${record[-1]}" = $'completed=true\n' ] || continue
    token=${candidate#"$1/$2."}
    token=${token%.verified}
    receipt_token_is_valid "$token" || continue
    producer=${token##*.}
    boot_id=${record[4]#boot_id=}
    boot_id=${boot_id%$'\n'}
    start_time=${record[5]#producer_start_time=}
    start_time=${start_time%$'\n'}
    [[ $boot_id =~ ^[A-Fa-f0-9-]+$ && $start_time =~ ^[0-9]+$ ]] || continue
    if [ "$boot_id" = "$current_boot_id" ] && [ -e "/proc/$producer" ]; then
      current_start_time=$(producer_start_time "$producer") || continue
      [ "$start_time" != "$current_start_time" ] || continue
    fi
    if [ -z "$verified_receipt_token" ] \
      || [ "$((10#${token%%.*}))" -gt "$((10#${verified_receipt_token%%.*}))" ]; then
      verified_receipt_token=$token
    fi
  done
  [ -n "$verified_receipt_token" ]
}

# 検証の状態は cache root から project まで自分だけが書ける実 directory に限る。
# symlink や他人の directory を辿って控え、実行枠、一時 file を置かない。
state_directory_is_private() {
  test ! -L "$1" && test -d "$1" && test "$(stat -c %u "$1")" = "$(id -u)"
}

state_file_is_private() {
  test ! -L "$1" && test -f "$1" && test "$(stat -c %u "$1")" = "$(id -u)"
}

ensure_state_directory() {
  local path=$1
  if mkdir -m 700 "$path" 2>/dev/null; then
    return
  fi
  state_directory_is_private "$path" || return 1
  chmod 700 "$path" || return 1
  test "$(stat -c %a "$path")" = 700
}

ensure_project_state() {
  mkdir -p -- "${cache_root%/*}" || return 1
  ensure_state_directory "$cache_root" \
    && ensure_state_directory "$verification_root" \
    && ensure_state_directory "$1"
}

project_state_is_private() {
  state_directory_is_private "$cache_root" \
    && state_directory_is_private "$verification_root" \
    && state_directory_is_private "$1"
}

session_name_is_valid() {
  [ -n "$1" ] && [ "$1" != . ] && [ "$1" != .. ] && [[ $1 != */* ]]
}

walk_session_state() {
  local step=$1 session=$2 child=${3-} path
  local -a directories=("$cache_root" "$verification_root" "$sessions_root" "$sessions_root/$session")
  [ -z "$child" ] || directories+=("$sessions_root/$session/$child")
  for path in "${directories[@]}"; do
    "$step" "$path" || return 1
  done
}

ensure_session_state() {
  if session_name_is_valid "$1" \
    && mkdir -p -- "${cache_root%/*}" \
    && walk_session_state ensure_state_directory "$@"; then
    return 0
  fi
  printf 'dotfiles-agent-gate: session の状態 directory を安全に確保できないため控えない: %s\n' "$sessions_root/$1" >&2
  return 1
}

session_state_is_private() {
  if session_name_is_valid "$1" && walk_session_state state_directory_is_private "$@"; then
    return 0
  fi
  printf 'dotfiles-agent-gate: session の状態が自分だけの実 directory でないため辿らない: %s\n' "$sessions_root/$1" >&2
  return 1
}

store_state() {
  local path=$1 content=$2
  if { [ -e "$path" ] || [ -L "$path" ]; } && ! state_file_is_private "$path"; then
    printf 'dotfiles-agent-gate: 控えの置き場所が自分の通常 file でないため控えない: %s\n' "$path" >&2
    return 1
  fi
  printf '%s\n' "$content" >"$path"
}

# 自分で作る一時 file が検査する木の中へ入ると、未追跡 file として照合値へ混ざる。
# TMPDIR は空文字列でも symlink でも木の中を指し得るため、物理 path で比べる。
scratch_is_outside_repo() {
  local top physical path
  top=$(realpath -e -- "$1") || return 1
  for path in "${TMPDIR:-/tmp}" "$cache_root"; do
    physical=$(realpath -m -- "$path") || return 1
    case $physical/ in
    "$top"/*) return 1 ;;
    esac
  done
}

# 照合の一時 directory。agent session では launcher が metadata で証明した session の scratch を使い、
# session の終了で launcher が回収する。TMPDIR の値は呼び出し側が決められるため直接は信用しない。
# session の外では、実行枠の中で走行 token を名に持つ project の状態 directory へ置く。
# どちらも EXIT trap、gate discard、消えた producer の回収のいずれかで捨てる。
# shellcheck disable=SC2329 # EXIT trap が関数を名前で呼ぶ。
release_scratch() {
  [ -z "$witness_scratch" ] || rm -rf --one-file-system -- "$witness_scratch" || true
  [ -z "$receipt_scratch" ] || rm -f -- "$receipt_scratch" || true
  witness_scratch=
  receipt_scratch=
}

begin_scratch() {
  local state=$1 token=$2 root
  if root=$(runtime_scratch_root); then
    witness_scratch=$(mktemp -d "$root/dotfiles-gate-witness.XXXXXXXX") || return 1
  else
    witness_scratch=$(mktemp -d "$state/.witness.$token.XXXXXXXX") || return 1
  fi
  trap release_scratch EXIT
}

# producer が消えたことが確かな場合だけ 0 で返る。開始時刻を読めないなど生死を確定できない場合は 1 で返り、捨てない。
receipt_producer_is_gone() {
  local pid=${1##*.} boot_id=${2-} start_time=${3-} current_boot_id current_start_time
  IFS= read -r current_boot_id </proc/sys/kernel/random/boot_id || return 1
  [ -z "$boot_id" ] || [ "$boot_id" = "$current_boot_id" ] || return 0
  [ -e "/proc/$pid" ] || return 0
  [ -n "$start_time" ] || return 1
  current_start_time=$(producer_start_time "$pid") || return 1
  [ "$start_time" != "$current_start_time" ]
}

# 走行の producer が消えた後に残った仮の控え、書込み途中の file、照合の一時 directory、
# 完了印の無い公開済みの控えを捨てる。実行枠の中で呼ぶため、生きた producer の控えは公開を終える直前の走行だけである。
reap_dead_receipts() {
  local state=$1 file name token boot_id start_time
  local -a record
  for file in "$state"/.pending.* "$state"/*.verified; do
    [ -f "$file" ] || continue
    name=${file##*/}
    case $name in
    .pending.*) token=${name#.pending.} ;;
    *.verified)
      token=${name#*.}
      token=${token%.verified}
      ;;
    esac
    receipt_token_is_valid "$token" || continue
    mapfile -t record <"$file" || continue
    [ "${#record[@]}" -ge 6 ] && [ "${record[0]}" = version=4 ] || continue
    [ "${record[6]-}" != completed=true ] || continue
    boot_id=${record[4]#boot_id=}
    start_time=${record[5]#producer_start_time=}
    if receipt_producer_is_gone "$token" "$boot_id" "$start_time"; then
      rm -f -- "$file"
    fi
  done
  for file in "$state"/.receipt.*; do
    [ -f "$file" ] || continue
    token=${file##*/.receipt.}
    token=${token%.*}
    receipt_token_is_valid "$token" || continue
    if receipt_producer_is_gone "$token"; then
      rm -f -- "$file"
    fi
  done
  for file in "$state"/.witness.*; do
    [ -d "$file" ] && [ ! -L "$file" ] || continue
    token=${file##*/.witness.}
    token=${token%.*}
    receipt_token_is_valid "$token" || continue
    if receipt_producer_is_gone "$token"; then
      rm -rf --one-file-system -- "$file"
    fi
  done
}

# 同じ project の T1 が一度に一つだけ走るための flock の相手。file は project の状態 directory に常に置く。
command_slot() {
  local repo=${1:-$PWD} top state slot
  top=$(repo_top_of "$repo") || fail 'git の木の中で呼ぶ'
  state=$(state_dir_of "$top") || fail 'git の木の中で呼ぶ'
  ensure_project_state "$state" || fail "検証の状態 directory を安全に確保できない: $state"
  slot=$state/run.lock
  if [ -e "$slot" ] || [ -L "$slot" ]; then
    state_file_is_private "$slot" || fail "実行枠が自分の通常 file でない: $slot"
  else
    : >>"$slot" || fail "実行枠を作れない: $slot"
  fi
  chmod 600 "$slot" || fail "実行枠の権限を閉じられない: $slot"
  printf '%s\n' "$slot"
}

command_record() {
  local repo=${1:-$PWD} text=${2:-} token=${3:-} top state before after witness boot_id start_time
  receipt_token_is_valid "$token" || fail 'record には正しい --pending が要る'
  top=$(repo_top_of "$repo") || return 0
  [ "$(realpath -e -- "$repo")" = "$(realpath -e -- "$top")" ] || return 0
  state=$(state_dir_of "$top") || return 0
  [ -n "$text" ] && [ "$text" = "$(declared_entry_of "$top")" ] || return 0
  IFS= read -r boot_id </proc/sys/kernel/random/boot_id || return 0
  start_time=$(producer_start_time "${token##*.}") || return 0
  ensure_project_state "$state" || fail "検証の状態 directory を安全に確保できない: $state"
  if ! scratch_is_outside_repo "$top"; then
    printf 'dotfiles-agent-gate: TMPDIR か cache が検査する木の中にあり、一時 file が照合値へ混ざるため証跡を作らない: %s\n' "$top" >&2
    return 0
  fi
  begin_scratch "$state" "$token" || fail '照合の一時 directory を作れない'
  reap_dead_receipts "$state"
  # 公開前に同じ token の控えを結び直さない
  [ ! -f "$state/.pending.$token" ] || return 0
  before=$(source_fingerprint "$top")
  if ! witness=$(source_witness "$top"); then
    printf 'dotfiles-agent-gate: 木を照合できないため、この走行の証跡を作らない: %s\n' "$top" >&2
    return 0
  fi
  after=$(source_fingerprint "$top")
  if [ "$before" != "$after" ]; then
    printf 'dotfiles-agent-gate: 採取の間に木が変わったため、この走行の証跡を作らない: %s\n' "$top" >&2
    return 0
  fi
  receipt_scratch=$(mktemp "$state/.receipt.$token.XXXXXXXX")
  printf 'version=4\nsource=%s\ncommand=%s\nat=%s\nboot_id=%s\nproducer_start_time=%s\n' \
    "$before" "$text" "$(date -Iseconds)" "$boot_id" "$start_time" >"$receipt_scratch"
  mv -T -- "$receipt_scratch" "$state/.pending.$token"
  receipt_scratch=
  printf '%s\n' "$witness"
}

command_publish() {
  local repo=${1:-$PWD} token=${2:-} expected=${3:-} top state pending current source=
  receipt_token_is_valid "$token" || fail 'publish には正しい --pending が要る'
  [[ $expected =~ ^[0-9a-f]{64}$ ]] || fail 'publish には正しい --witness が要る'
  top=$(repo_top_of "$repo") || return 0
  state=$(state_dir_of "$top") || return 0
  pending=$state/.pending.$token
  [ -f "$pending" ] || return 0
  begin_scratch "$state" "$token" || fail '照合の一時 directory を作れない'
  if ! current=$(source_witness "$top") || [ "$current" != "$expected" ]; then
    rm -f -- "$pending"
    printf 'dotfiles-agent-gate: 検査の間に木が変わったため、証跡を公開しない: %s\n' "$top" >&2
    return 0
  fi
  { IFS= read -r _ && IFS= read -r source; } <"$pending" || true
  source=${source#source=}
  if ! [[ $source =~ ^[0-9a-f]{64}$ ]]; then
    rm -f -- "$pending"
    fail '仮の控えの指紋が読めないため公開しない'
  fi
  mv -T -- "$pending" "$state/$source.$token.verified"
  printf '%s\n' "$state/$source.$token.verified"
}

command_discard() {
  local token=$1 scratch
  receipt_token_is_valid "$token" || fail 'discard には正しい --pending が要る'
  rm -f -- "$verification_root"/*/.pending."$token" \
    "$verification_root"/*/*."$token".verified "$verification_root"/*/.receipt."$token".*
  for scratch in "$verification_root"/*/.witness."$token".*; do
    [ -d "$scratch" ] && [ ! -L "$scratch" ] || continue
    rm -rf --one-file-system -- "$scratch"
  done
}

command_settle() {
  local repo=${1:-$PWD} token=${2:-} top state own name fingerprint other other_token
  receipt_token_is_valid "$token" || fail 'settle には正しい --pending が要る'
  top=$(repo_top_of "$repo") || return 0
  state=$(state_dir_of "$top") || return 0
  for own in "$state"/*."$token".verified; do
    [ -f "$own" ] || return 0
    name=${own##*/}
    fingerprint=${name%%.*}
    for other in "$state/$fingerprint".*.verified; do
      [ -f "$other" ] || continue
      name=${other##*/}
      other_token=${name#"$fingerprint".}
      other_token=${other_token%.verified}
      receipt_token_is_valid "$other_token" || continue
      if [ "$((10#${other_token%%.*}))" -lt "$((10#${token%%.*}))" ]; then
        rm -f -- "$other"
      fi
    done
  done
}

command_arm() {
  local session=$1 path=${2:-$PWD} top id
  [ -n "$session" ] || fail 'arm には --session が要る'
  [ -e "$path" ] || path=$(dirname -- "$path")
  [ -d "$path" ] || path=$(dirname -- "$path")
  top=$(repo_top_of "$path") || return 0
  id=$(project_id_of "$top") || return 0
  ensure_session_state "$session" || return 1
  store_state "$sessions_root/$session/$id" "$top"
}

# shell の呼び出しは綴りから書き込み先を読めない。呼ぶ前と後で作業場所の木の指紋を比べ、
# 変わった repository だけを控える。読むだけの呼び出しは指紋が変わらないので stop を止めない。
# 後の側は前に控えた repository を測る。呼び出しの中で cwd が移っても、同じ木を比べる。
command_observe() {
  local session=$1 call=$2 phase=$3 path=$4 calls state top before
  local -a held
  [ -n "$session" ] && [ -n "$call" ] || return 0
  calls="$sessions_root/$session/calls"
  state="$calls/$(printf '%s' "$call" | sha256sum | cut -d ' ' -f 1)"
  case $phase in
  PreToolUse)
    top=$(repo_top_of "$path") || return 0
    before=$(source_fingerprint "$top") || return 0
    ensure_session_state "$session" calls || return 1
    store_state "$state" "$before"$'\n'"$top"
    ;;
  PostToolUse | PostToolUseFailure)
    [ -e "$state" ] || [ -L "$state" ] || return 0
    session_state_is_private "$session" calls || return 1
    state_file_is_private "$state" || return 1
    mapfile -t held <"$state"
    rm -f -- "$state"
    before=${held[0]-} top=${held[1]-}
    [ -n "$before" ] && [ -d "$top" ] || return 0
    [ "$(source_fingerprint "$top")" = "$before" ] || command_arm "$session" "$top"
    ;;
  esac
}

# 未検証なら理由を stdout と stderr の両方へ出して 1 で終わる。
# claude は stderr を、omp の拡張は stdout を読む。
command_check() {
  local repo=$1 top state entry fingerprint reason
  top=$(repo_top_of "$repo") || return 0
  entry=$(declared_entry_of "$top") || return $?
  [ -n "$entry" ] || return 0
  state=$(state_dir_of "$top") || return 0
  fingerprint=$(source_fingerprint "$top")
  if verified_receipt_exists "$state" "$fingerprint"; then
    command_settle "$top" "$verified_receipt_token" || true
    return 0
  fi
  if project_state_is_private "$state" && state_file_is_private "$state/$fingerprint.waived"; then
    printf '%s を未検証のまま通した理由: %s\n' \
      "$top" "$(sed -n 's/^reason=//p' "$state/$fingerprint.waived")" >&2
    return 0
  fi
  reason=$(
    printf '%s の検証入口が、いまの木に対して通っていない。\n' "$top"
    printf '  通す: cd %s && dotfiles-agent-verify -- %s\n' "$top" "$entry"
    printf '  通せない事情があるなら理由を残して抜ける: dotfiles-agent-gate waive --repo %s --reason "<理由>"\n' "$top"
  )
  printf '%s\n' "$reason"
  printf '%s\n' "$reason" >&2
  return 1
}

command_waive() {
  local repo=${1:-$PWD} reason=$2 top state fingerprint record
  [ -n "$reason" ] || fail 'waive には --reason が要る'
  top=$(repo_top_of "$repo") || fail 'git の木の中で呼ぶ'
  state=$(state_dir_of "$top") || fail 'git の木の中で呼ぶ'
  ensure_project_state "$state" || fail "検証の状態 directory を安全に確保できない: $state"
  fingerprint=$(source_fingerprint "$top")
  printf -v record 'version=1\nsource=%s\nreason=%s\nat=%s' "$fingerprint" "$reason" "$(date -Iseconds)"
  store_state "$state/$fingerprint.waived" "$record" || return 1
  printf '%s を未検証のまま通す理由を控えた: %s\n' "$top" "$reason"
}

# TMPDIR の値と session 名の形は呼び出し側が決められるため launcher の metadata を伴わない許可は不可
runtime_scratch_root() {
  local physical sessions relative session metadata
  [ -n "${TMPDIR-}" ] || return 1
  [ -n "${DOTFILES_AGENT_SESSION_ID-}" ] || return 1
  physical=$(realpath -e -- "$TMPDIR" 2>/dev/null) || return 1
  sessions=$(realpath -e -- "$cache_root/sessions" 2>/dev/null) || return 1
  [ -d "$physical" ] || return 1
  case $physical in
  "$sessions"/*) relative=${physical#"$sessions"/} ;;
  *) return 1 ;;
  esac
  session=${relative%/tmp}
  [ "$relative" = "$session/tmp" ] && [[ $session =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [ "$session" = "$DOTFILES_AGENT_SESSION_ID" ] || return 1
  metadata="$sessions/$session/metadata.json"
  [ -f "$metadata" ] && [ ! -L "$metadata" ] || return 1
  jq -e --arg session "$session" '.version == 1 and .session_id == $session' \
    "$metadata" >/dev/null 2>&1 || return 1
  printf '%s\n' "$physical"
}

command_hook() {
  local kind=$1 payload session cwd path marker held reason status=0
  payload=$(cat)
  session=$(printf '%s' "$payload" | jq -r '.session_id // empty')
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')

  case $kind in
  arm)
    path=$(printf '%s' "$payload" |
      jq -r '.tool_input.file_path // .tool_input.path // .tool_input.filePath // empty')
    case $path in xd://* | agent://* | proc://* | local://* | cfg://* | ssh://*) return 0 ;; esac
    [ -n "$path" ] || path=$cwd
    case $path in /*) ;; *) path="$cwd/$path" ;; esac
    command_arm "$session" "$path" || true
    ;;
  observe)
    # 作業場所は tool の cwd を先に採る。omp の bash は session の cwd からの相対も許す。
    path=$(printf '%s' "$payload" | jq -r '.tool_input.cwd // empty')
    [ -n "$path" ] || path=$cwd
    case $path in /*) ;; *) path="$cwd/$path" ;; esac
    command_observe "$session" \
      "$(printf '%s' "$payload" | jq -r '.tool_use_id // empty')" \
      "$(printf '%s' "$payload" | jq -r '.hook_event_name // empty')" \
      "$path" || true
    exit 0
    ;;
  stop)
    if [ -n "$session" ] && { [ -e "$sessions_root/$session" ] || [ -L "$sessions_root/$session" ]; }; then
      if reason=$(session_state_is_private "$session" 2>&1); then
        # skills は Skill の読取を控えていた旧 generation の残りである。読む者がいないため calls と同じく捨てる。
        for marker in "$sessions_root/$session"/*; do
          [ -e "$marker" ] || [ -L "$marker" ] || continue
          if case ${marker##*/} in
            calls | skills) state_directory_is_private "$marker" ;;
            *) state_file_is_private "$marker" ;;
          esac; then
            case ${marker##*/} in
            calls | skills) rm -rf -- "$marker"; continue ;;
            esac
            held=$(cat "$marker")
            [ -d "$held" ] || continue
            command_check "$held" || status=2
          else
            printf 'dotfiles-agent-gate: 不正な状態の控えを検証済みと扱わない: %s\n' "$marker" | tee /dev/stderr
            status=2
          fi
        done
      else
        reason=$(printf '%s\n  控えた repository を確かめられないため、検証済みとは扱わず止める。' "$reason")
        printf '%s\n' "$reason"
        printf '%s\n' "$reason" >&2
        status=2
      fi
    fi
    exit "$status"
    ;;
  *) usage ;;
  esac
}

main() {
  local command=${1-}
  [ -n "$command" ] || usage
  shift || true

  local repo=$PWD session="" reason="" text="" path="" pending="" witness=""
  local -a policy_args=()
  while [ "$#" -gt 0 ]; do
    case $1 in
    --repo)
      repo=$2
      shift 2
      ;;
    --policy)
      [ "$#" -ge 2 ] && [ "${#policy_args[@]}" -eq 0 ] || usage
      policy_args=(--policy "$2")
      shift 2
      ;;
    --session)
      session=$2
      shift 2
      ;;
    --reason)
      reason=$2
      shift 2
      ;;
    --command)
      text=$2
      shift 2
      ;;
    --path)
      path=$2
      shift 2
      ;;
    --pending)
      pending=$2
      shift 2
      ;;
    --witness)
      witness=$2
      shift 2
      ;;
    arm | stop | observe) break ;;
    *) usage ;;
    esac
  done
  if [ "${#policy_args[@]}" -gt 0 ] && [ "$command" != entry ] && [ "$command" != budget ] \
    && [ "$command" != push-declaration ]; then
    usage
  fi

  case $command in
  slot) command_slot "$repo" ;;
  record) command_record "$repo" "$text" "$pending" ;;
  publish) command_publish "$repo" "$pending" "$witness" ;;
  discard) command_discard "$pending" ;;
  arm) command_arm "$session" "${path:-$repo}" ;;
  check) command_check "$repo" ;;
  waive) command_waive "$repo" "$reason" ;;
  entry) entry_of "$(repo_top_of "$repo")" ;;
  candidates) candidates_of "$(repo_top_of "$repo")" ;;
  budget) budget_of "$repo" ;;
  snapshot) snapshot_of "$repo" ;;
  push-declaration) command_push_declaration "$repo" ;;
  hook) command_hook "${1-}" ;;
  *) usage ;;
  esac
}

main "$@"
