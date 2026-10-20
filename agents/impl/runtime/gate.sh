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

  record --pending TOKEN [--repo DIR] [--command TEXT]
                                        DIR が根で TEXT が検証入口の綴りなら公開しない仮の控えを作る
  publish --pending TOKEN [--repo DIR]  仮の控えを木の控えとして公開する。deadline の下で呼ぶ
  discard --pending TOKEN             その走行の仮の控えと公開した控え、一時fileだけを捨てる
  arm --session ID [--path PATH]        その session が編集した repository を控える
  check [--repo DIR] [--session ID]     未検証なら理由を出して 1 で終わる
  waive --reason TEXT [--repo DIR]      理由を残していまの木を一度だけ通す
  entry [--repo DIR] [--policy FILE]      repository が登録する検証入口の綴りを評価器を起動せずに答える
  candidates [--repo DIR]               予算が読めない間に、検証入口になり得る綴りを評価せずに一行ずつ答える
  budget [--repo DIR] [--policy FILE]     その repository の T1 の時間予算を秒で答える。宣言が無い、または不正なら理由を出して 1 で終わる
  snapshot [--repo DIR]                 一度読んだ静的な検証宣言を JSON で答える。entry と budget の --policy に渡す
  skill --path PATH                     その綴りを触る前に読む skill の名を答える
  learned --session ID --path NAME      管理者が既存の配備済み skill 本文を明示的に承認する
  teach --session ID --path PATH        読んでいなければ理由を出して 1 で終わる
  hook <arm|edit|learn|observe|stop>    client の hook から stdin の JSON で起こす
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

# いまの木の指紋。HEAD と追跡済みの差分と未追跡の中身だけから採る。
# verify の指紋と違い環境も argv も混ぜない。同じ木なら誰が測っても同じ値になることが要る。
source_fingerprint() {
  local repo=$1 head path
  head=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null || printf 'none')
  {
    printf 'dotfiles-agent-gate-v3\0head\0%s\0tracked\0' "$head"
    git -C "$repo" -c color.ui=false diff --binary --full-index --no-ext-diff --no-textconv HEAD --
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

state_dir_of() {
  local repo=$1 id
  id=$(project_id_of "$repo") || return 1
  printf '%s/%s' "$verification_root" "$id"
}

ensure_dir() {
  mkdir -p "$1"
  chmod 700 "$1"
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
  for candidate in "$1/$2".*.verified; do
    [ -f "$candidate" ] || continue
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

command_record() {
  local repo=${1:-$PWD} text=${2:-} token=${3:-} top state fingerprint boot_id start_time
  receipt_token_is_valid "$token" || fail 'record には正しい --pending が要る'
  top=$(repo_top_of "$repo") || return 0
  [ "$(realpath -e -- "$repo")" = "$(realpath -e -- "$top")" ] || return 0
  state=$(state_dir_of "$top") || return 0
  # 後段の再採取でsourceが結び直されるため同じtokenへの上書きは不可
  [ ! -f "$state/.pending.$token" ] || return 0
  [ -n "$text" ] && [ "$text" = "$(declared_entry_of "$top")" ] || return 0
  IFS= read -r boot_id </proc/sys/kernel/random/boot_id || return 0
  start_time=$(producer_start_time "${token##*.}") || return 0
  ensure_dir "$state"
  fingerprint=$(source_fingerprint "$top")
  receipt_scratch=$(mktemp "$state/.receipt.$token.XXXXXXXX")
  trap 'rm -f -- "$receipt_scratch"' EXIT
  printf 'version=4\nsource=%s\ncommand=%s\nat=%s\nboot_id=%s\nproducer_start_time=%s\n' \
    "$fingerprint" "$text" "$(date -Iseconds)" "$boot_id" "$start_time" >"$receipt_scratch"
  mv -T -- "$receipt_scratch" "$state/.pending.$token"
  trap - EXIT
}

command_publish() {
  local repo=${1:-$PWD} token=${2:-} top state pending source=
  receipt_token_is_valid "$token" || fail 'publish には正しい --pending が要る'
  top=$(repo_top_of "$repo") || return 0
  state=$(state_dir_of "$top") || return 0
  pending=$state/.pending.$token
  [ -f "$pending" ] || return 0
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
  for scratch in "$verification_root"/.fingerprint."$token".*; do
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
  ensure_dir "$sessions_root/$session"
  printf '%s\n' "$top" >"$sessions_root/$session/$id"
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
    ensure_dir "$calls"
    printf '%s\n%s\n' "$before" "$top" >"$state"
    ;;
  PostToolUse | PostToolUseFailure)
    [ -f "$state" ] || return 0
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
  if [ -f "$state/$fingerprint.waived" ]; then
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
  local repo=${1:-$PWD} reason=$2 top state fingerprint
  [ -n "$reason" ] || fail 'waive には --reason が要る'
  top=$(repo_top_of "$repo") || fail 'git の木の中で呼ぶ'
  state=$(state_dir_of "$top") || fail 'git の木の中で呼ぶ'
  ensure_dir "$state"
  fingerprint=$(source_fingerprint "$top")
  printf 'version=1\nsource=%s\nreason=%s\nat=%s\n' \
    "$fingerprint" "$reason" "$(date -Iseconds)" >"$state/$fingerprint.waived"
  printf '%s を未検証のまま通す理由を控えた: %s\n' "$top" "$reason"
}

# その綴りを触る前に読ませる skill。判断の時点で規律を呼ばずに書くと、
# 後段の門は「稚拙な設計が正しく実装されたこと」しか検められない。
skill_for() {
  case $1 in
  *.md | *.txt | *.json | *.lock) printf '' ;;
  */tests/* | *.test.ts | *.test.tsx | *Tests.cs | *.doubles.ts | *.doubles.tsx | *.feature)
    printf ''
    ;;
  */application/ports/* | */contracts/canonical/* | *.tsp) printf 'codebase-design' ;;
  *Refusal*.cs | *Failure*.cs | */errors/*) printf 'codebase-design' ;;
  */domain/* | */entities/*) printf 'domain-modeling' ;;
  *.tsx | */surfaces/viewer/* | */runtimes/web/*) printf 'ui-design' ;;
  *.csproj) printf 'codebase-design' ;;
  */core/* | */surfaces/* | */libs/*) printf 'codebase-design' ;;
  *) printf '' ;;
  esac
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

# Git 探索は所有権・環境変数で非検出になるため git rev-parse による判定は不可
isolated_scratch() {
  local canonical=$1 root dir
  local -a entries
  root=$(runtime_scratch_root) || return 1
  case $canonical in
  "$root"/*) ;;
  *) return 1 ;;
  esac
  dir=${canonical%/*}
  while :; do
    if [ -e "$dir/.git" ] || [ -L "$dir/.git" ]; then
      if [ -d "$dir/.git" ] && [ ! -L "$dir/.git" ] &&
        [ -r "$dir/.git" ] && [ -x "$dir/.git" ] &&
        (
          shopt -s nullglob dotglob
          entries=("$dir/.git/"*)
          [ "${#entries[@]}" -eq 0 ]
        ); then
        :
      else
        return 1
      fi
    fi
    [ -n "$dir" ] || break
    dir=${dir%/*}
  done
  return 0
}

# tests/.. と symlink で行き先の規則を免れるため綴りへの規則適用は不可
skill_required_for() {
  local canonical
  if ! canonical=$(realpath -m -- "$1" 2>/dev/null); then
    skill_for "$1"
    return
  fi
  if isolated_scratch "$canonical"; then
    return 0
  fi
  skill_for "$canonical"
}

# その skill が配備されているか。配られていない名で止めると、読みようがない要求になる。
skill_stands() {
  local named=$1 root
  local -a roots=(@skillRoots@)
  for root in "${roots[@]}"; do
    [ -d "$HOME/$root/$named" ] && return 0
  done
  return 1
}

skill_name_is_valid() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
}

skill_body_of() {
  local named=$1 root body
  local -a roots=(@skillRoots@)
  skill_name_is_valid "$named" || return 1
  for root in "${roots[@]}"; do
    body="$HOME/$root/$named/SKILL.md"
    [ -f "$body" ] || continue
    printf '%s\n' "$body"
    return 0
  done
  return 1
}

skill_read_in() {
  local path=$1 root relative named
  local -a roots=(@skillRoots@)
  case $path in
  skill://*)
    named=${path#skill://}
    named=${named%/SKILL.md}
    skill_body_of "$named"
    return
    ;;
  esac
  for root in "${roots[@]}"; do
    case $path in
    "$HOME/$root/"*) relative=${path#"$HOME/$root/"} ;;
    *) continue ;;
    esac
    named=${relative%%/*}
    skill_name_is_valid "$named" || return 1
    [ "$relative" = "$named/SKILL.md" ] && [ -f "$path" ] || return 1
    printf '%s\n' "$path"
    return 0
  done
  return 1
}

# argv の長さ制限を超える payload の引数渡しは不可
# JS 本体の heredoc が stdin を使うため payload と同じ FD への入力は不可
read_result_proof() {
  local payload=$1 body=$2
  node --input-type=commonjs - "$body" 3< <(printf '%s' "$payload") <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const requireProof = condition => { if (!condition) process.exit(1); };
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const normalize = text => {
  requireProof(typeof text === "string");
  return text.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n");
};
try {
  const event = JSON.parse(fs.readFileSync(3, "utf8"));
  const physicalPath = fs.realpathSync(process.argv[2]);
  const bytes = fs.readFileSync(physicalPath);
  const complete = normalize(bytes.toString("utf8"));
  const withoutFinalNewline = complete.endsWith("\n") ? complete.slice(0, -1) : complete;
  const matchesBody = text => {
    const actual = normalize(text);
    return actual === complete || actual === withoutFinalNewline;
  };
  let actualPath;
  if (event.tool_name === "read") {
    const result = event.tool_result;
    requireProof(object(result) && object(result.details));
    const details = result.details;
    requireProof(details.truncation == null || (object(details.truncation) && details.truncation.truncated === false));
    requireProof(details.summary == null);
    requireProof(details.meta == null || object(details.meta));
    requireProof(details.meta?.truncation == null && details.meta?.artifactError == null);
    requireProof(details.meta?.limits?.columnTruncated == null);
    requireProof(Number.isSafeInteger(details.totalLines) && details.totalLines > 0);
    const display = details.displayContent;
    requireProof(object(display) && display.startLine === 1 && matchesBody(display.text));
    requireProof(Array.isArray(display.lineNumbers) && display.lineNumbers.length === details.totalLines);
    requireProof(display.lineNumbers.every((line, index) => line === index + 1));
    requireProof(Array.isArray(result.content) && result.content.length > 0);
    const rendered = normalize(result.content.map(block => {
      requireProof(object(block) && block.type === "text" && typeof block.text === "string");
      return block.text;
    }).join("\n"));
    const displayed = normalize(display.text);
    requireProof(displayed.length > 0);
    let included = rendered.includes(displayed);
    if (!included) {
      const lines = displayed.split("\n");
      for (const separator of [":", "|"]) {
        if (rendered.includes(lines.map((line, index) => `${index + 1}${separator}${line}`).join("\n"))) {
          included = true;
          break;
        }
      }
    }
    requireProof(included);
    actualPath = details.resolvedPath ?? (details.meta?.source?.type === "path" ? details.meta.source.value : undefined);
  } else {
    requireProof(event.tool_name === "Read" && event.tool_response?.type === "text");
    const file = event.tool_response.file;
    requireProof(object(file) && file.startLine === 1 && file.truncatedByTokenCap !== true);
    requireProof(Number.isSafeInteger(file.totalLines) && file.totalLines > 0 && file.numLines === file.totalLines);
    requireProof(matchesBody(file.content));
    actualPath = file.filePath;
  }
  requireProof(typeof actualPath === "string" && actualPath.length > 0);
  const cwd = typeof event.cwd === "string" ? event.cwd : process.cwd();
  requireProof(fs.realpathSync(path.resolve(cwd, actualPath)) === physicalPath);
  console.log(JSON.stringify({ digest: crypto.createHash("sha256").update(bytes).digest("hex") }));
} catch {
  process.exit(1);
}
NODE
}

record_skill_read() {
  local session=$1 body=$2 digest=${3-} named resolved
  [ -n "$session" ] || return 0
  named=${body%/SKILL.md}
  named=${named##*/}
  if [ -z "$digest" ]; then
    resolved=$(realpath -e -- "$body") || return 1
    digest=$(sha256sum <"$resolved" | cut -d ' ' -f 1) || return 1
  fi
  ensure_dir "$sessions_root/$session/skills"
  printf '%s\n%s\n' "$digest" "$body" >"$sessions_root/$session/skills/$named"
}

command_learned() {
  local session=$1 named=$2 body
  [ -n "$session" ] && [ -n "$named" ] || fail 'learned には --session と --path NAME が要る'
  body=$(skill_body_of "$named") || fail "配備済み skill の本文が存在しない: $named"
  record_skill_read "$session" "$body"
}

command_teach() {
  local session=$1 path=$2 named marker body resolved digest
  local -a held
  named=$(skill_required_for "$path")
  [ -n "$named" ] || return 0
  skill_stands "$named" || return 0
  [ -n "$session" ] || return 0
  marker="$sessions_root/$session/skills/$named"
  if [ -f "$marker" ] &&
    mapfile -t held <"$marker" &&
    [ "${#held[@]}" -eq 2 ] &&
    body=$(skill_read_in "${held[1]}") &&
    [[ $body == */"$named"/SKILL.md ]] &&
    resolved=$(realpath -e -- "$body") &&
    digest=$(sha256sum <"$resolved" | cut -d ' ' -f 1) &&
    [ "${held[0]}" = "$digest" ]; then
    return 0
  fi
  printf '%s を触る前に skill://%s を読む。\n' "$path" "$named" | tee /dev/stderr
  printf '  この周で現在の本文をまだ読んでいない。規律を呼ばずに書いた設計は、後段の門では直せない。\n' |
    tee /dev/stderr
  return 1
}

command_hook() {
  local kind=$1 payload session cwd path body proof digest marker held status=0
  payload=$(cat)
  session=$(printf '%s' "$payload" | jq -r '.session_id // empty')
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')

  case $kind in
  arm)
    path=$(printf '%s' "$payload" |
      jq -r '.tool_input.file_path // .tool_input.path // .tool_input.filePath // empty')
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
  learn)
    printf '%s' "$payload" | jq -e '
      .hook_event_name == "PostToolUse" and
      (.tool_name == "read" or .tool_name == "Read") and
      .is_error != true and .isError != true and
      .tool_response.is_error != true and
      .tool_response.error == null and .tool_response.success != false and
      (.tool_input | type == "object" and (has("offset") or has("limit") | not))
    ' >/dev/null || exit 0
    path=$(printf '%s' "$payload" |
      jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filePath // empty')
    case $path in skill://* | /*) ;; *) path="$cwd/$path" ;; esac
    body=$(skill_read_in "$path") || exit 0
    proof=$(read_result_proof "$payload" "$body") || exit 0
    digest=$(printf '%s' "$proof" | jq -er '.digest | select(test("^[0-9a-f]{64}$"))') || exit 0
    record_skill_read "$session" "$body" "$digest"
    exit 0
    ;;
  edit)
    path=$(printf '%s' "$payload" |
      jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filePath // empty')
    [ -n "$path" ] || exit 0
    case $path in /*) ;; *) path="$cwd/$path" ;; esac
    command_teach "$session" "$path" || exit 2
    exit 0
    ;;
  stop)
    if [ -n "$session" ] && [ -d "$sessions_root/$session" ]; then
      # 前だけ控えて後が届かなかった呼び出し(他の hook や許可に止められたもの)の控えを捨てる。
      rm -rf -- "$sessions_root/$session/calls"
      for marker in "$sessions_root/$session"/*; do
        [ -d "$marker" ] && continue
        [ -f "$marker" ] || continue
        held=$(cat "$marker")
        [ -d "$held" ] || continue
        command_check "$held" || status=2
      done
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

  local repo=$PWD session="" reason="" text="" path="" pending=""
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
    arm | stop | edit | learn | observe) break ;;
    *) usage ;;
    esac
  done
  if [ "${#policy_args[@]}" -gt 0 ] && [ "$command" != entry ] && [ "$command" != budget ]; then
    usage
  fi

  case $command in
  record) command_record "$repo" "$text" "$pending" ;;
  publish) command_publish "$repo" "$pending" ;;
  discard) command_discard "$pending" ;;
  arm) command_arm "$session" "${path:-$repo}" ;;
  check) command_check "$repo" ;;
  waive) command_waive "$repo" "$reason" ;;
  entry) entry_of "$(repo_top_of "$repo")" ;;
  candidates) candidates_of "$(repo_top_of "$repo")" ;;
  budget) budget_of "$repo" ;;
  snapshot) snapshot_of "$repo" ;;
  learned) command_learned "$session" "$path" ;;
  teach) command_teach "$session" "$path" ;;
  skill) skill_required_for "$path" ;;
  hook) command_hook "${1-}" ;;
  *) usage ;;
  esac
}

main "$@"
