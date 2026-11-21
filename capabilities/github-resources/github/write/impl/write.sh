set +x

# 利用者の端末と同じ UID が、選んだ account の token で公式 gh の REST 呼出しを一度だけ送る。
# 操作と endpoint は下の case に固定し、任意の API は通さない。merge、削除、history の変更はここに置かない

readonly accounts_file=@accounts@
readonly gh_host=@host@
readonly gh=@gh@

usage() {
  cat <<'EOF'
Usage: dotfiles-github-write --account ID --login LOGIN OPERATION [OPTIONS]

  ID     dotfiles account id; the read target github-ID resolves the same token
  LOGIN  GitHub login that ID's token must authenticate as

Operations (one write request each, never retried):
  issue-create  --repo OWNER/REPO --title TITLE [--body-file FILE]
  issue-update  --repo OWNER/REPO --number N and at least one of
                [--title TITLE] [--body-file FILE] [--state open|closed]
                [--state-reason completed|not_planned|duplicate|reopened]
                [--labels-json JSON] [--assignees-json JSON] [--milestone N|none]
                (also sets labels, assignees and milestone of a pull request;
                the JSON arrays replace the whole set)
  comment       --repo OWNER/REPO --number N --body-file FILE
                (conversation comment on an issue or pull request)
  comment-edit  --repo OWNER/REPO --comment-id ID --body-file FILE
  pr-create     --repo OWNER/REPO --title TITLE --head [OWNER:]BRANCH --base BRANCH
                [--body-file FILE] [--draft]
  pr-update     --repo OWNER/REPO --number N and at least one of
                [--title TITLE] [--body-file FILE] [--state open|closed]
                [--base BRANCH] [--maintainer-can-modify true|false]
  pr-reviewers  --repo OWNER/REPO --number N and at least one of
                [--reviewers-json JSON] [--team-reviewers-json JSON]
  review        --repo OWNER/REPO --number N --commit SHA
                --event APPROVE|REQUEST_CHANGES|COMMENT [--body-file FILE]
                [--comments-file FILE]
                (submitted review; FILE holds a JSON array of
                {path, body, line|position, side?, start_line?, start_side?})
  review-reply  --repo OWNER/REPO --number N --comment-id ID --body-file FILE
  branch-create --repo OWNER/REPO --branch BRANCH --from-sha SHA
                (creates a new branch; an existing branch is never moved)

FILE "-" reads standard input. JSON is an array of strings.

Exit status:
  0  written; stdout is a JSON receipt with account, login, operation, result
  2  invalid request; nothing was sent
  3  credential or identity check failed; nothing was written
  4  the write was sent but not confirmed; read the target before any retry
EOF
}

fail() {
  local status=$1
  shift
  printf 'dotfiles-github-write: %s\n' "$*" >&2
  exit "$status"
}

# 呼出し元の GitHub 用の環境は別 account の token や host を運び得る。ここで渡す値だけを gh へ残す
while IFS= read -r name; do
  case ${name} in
    GH_* | GITHUB_* | DEBUG) unset "${name}" ;;
  esac
done < <(compgen -e)

declare -A options=()
draft=false
operation=""

while (($# > 0)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --draft)
      [[ ${draft} == false ]] || fail 2 "--draft given twice"
      draft=true
      shift
      ;;
    --account | --login | --repo | --number | --title | --body-file | --head | --base | --commit | --event | \
      --comments-file | --comment-id | --state | --state-reason | --labels-json | --assignees-json | \
      --milestone | --maintainer-can-modify | --reviewers-json | --team-reviewers-json | --branch | --from-sha)
      if (($# < 2)) || [[ -z $2 ]]; then
        fail 2 "$1 needs a non-empty value"
      fi
      [[ -z ${options[$1]+set} ]] || fail 2 "$1 given twice"
      options[$1]=$2
      shift 2
      ;;
    -*) fail 2 "unknown option: $1" ;;
    *)
      [[ -z ${operation} ]] || fail 2 "only one operation is allowed: ${operation}, $1"
      operation=$1
      shift
      ;;
  esac
done

# required は全て必要、fields は少なくとも一つ必要、allowed は任意
fields=()
case ${operation} in
  issue-create)
    required=(--repo --title)
    allowed=(--body-file)
    ;;
  issue-update)
    required=(--repo --number)
    fields=(--title --body-file --state --state-reason --labels-json --assignees-json --milestone)
    allowed=()
    ;;
  comment)
    required=(--repo --number --body-file)
    allowed=()
    ;;
  comment-edit)
    required=(--repo --comment-id --body-file)
    allowed=()
    ;;
  pr-create)
    required=(--repo --title --head --base)
    allowed=(--body-file)
    ;;
  pr-update)
    required=(--repo --number)
    fields=(--title --body-file --state --base --maintainer-can-modify)
    allowed=()
    ;;
  pr-reviewers)
    required=(--repo --number)
    fields=(--reviewers-json --team-reviewers-json)
    allowed=()
    ;;
  review)
    required=(--repo --number --commit --event)
    allowed=(--body-file --comments-file)
    ;;
  review-reply)
    required=(--repo --number --comment-id --body-file)
    allowed=()
    ;;
  branch-create)
    required=(--repo --branch --from-sha)
    allowed=()
    ;;
  "")
    usage >&2
    exit 2
    ;;
  *) fail 2 "unsupported operation: ${operation}; merges, deletions, history changes and other writes are not handled here" ;;
esac

for option in --account --login "${required[@]}"; do
  [[ -n ${options[${option}]-} ]] || fail 2 "${operation} needs ${option}"
done
for option in "${!options[@]}"; do
  case " --account --login ${required[*]} ${fields[*]} ${allowed[*]} " in
    *" ${option} "*) ;;
    *) fail 2 "${operation} does not take ${option}" ;;
  esac
done
if ((${#fields[@]} > 0)); then
  present=false
  for option in "${fields[@]}"; do
    if [[ -n ${options[${option}]+set} ]]; then
      present=true
    fi
  done
  [[ ${present} == true ]] || fail 2 "${operation} needs at least one of ${fields[*]}"
fi
if [[ ${draft} == true && ${operation} != pr-create ]]; then
  fail 2 "${operation} does not take --draft"
fi

account=${options[--account]}
login=${options[--login]}
repo=${options[--repo]}

[[ ${account} =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail 2 "invalid account id: ${account}"
token_file=$(jq -r --arg account "${account}" '.[$account] // empty' "${accounts_file}")
[[ -n ${token_file} ]] || fail 2 "unknown account id: ${account}"
[[ ${login} =~ ^[A-Za-z0-9-]{1,39}$ ]] || fail 2 "invalid login: ${login}"
# repository 名の . と .. は API の path を別の resource へ移す
[[ ${repo} =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ && ${repo#*/} != . && ${repo#*/} != .. ]] ||
  fail 2 "invalid repository, expected OWNER/REPO: ${repo}"

positive() {
  [[ $2 =~ ^[1-9][0-9]{0,15}$ ]] || fail 2 "$1 must be a positive integer: $2"
}
full_sha() {
  [[ $2 =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail 2 "$1 must be a full lowercase commit SHA: $2"
}
one_of() {
  local option=$1 value=$2 candidate
  shift 2
  for candidate; do
    [[ ${value} == "${candidate}" ]] && return 0
  done
  fail 2 "${option} must be one of $*: ${value}"
}
# 一行の Git ref。gh への引数ではなく JSON の値として渡す
branch_pattern='^[^][[:space:][:cntrl:]:~^?*\\]+$'

[[ -z ${options[--number]-} ]] || positive --number "${options[--number]}"
[[ -z ${options[--comment-id]-} ]] || positive --comment-id "${options[--comment-id]}"
if [[ -n ${options[--title]+set} && ! ${options[--title]} =~ [^[:space:]] ]]; then
  fail 2 "--title is blank"
fi
if [[ -n ${options[--head]-} ]]; then
  head_branch=${options[--head]}
  if [[ ${head_branch} == *:* ]]; then
    [[ ${head_branch%%:*} =~ ^[A-Za-z0-9-]+$ ]] || fail 2 "invalid --head owner: ${head_branch}"
    head_branch=${head_branch#*:}
  fi
  [[ ${head_branch} =~ ${branch_pattern} ]] || fail 2 "invalid --head branch: ${options[--head]}"
fi
for option in --base --branch; do
  if [[ -n ${options[${option}]+set} && ! ${options[${option}]} =~ ${branch_pattern} ]]; then
    fail 2 "invalid ${option} branch: ${options[${option}]}"
  fi
done
if [[ -n ${options[--branch]-} && ${options[--branch]} == refs/* ]]; then
  fail 2 "--branch takes a branch name without refs/: ${options[--branch]}"
fi
[[ -z ${options[--commit]-} ]] || full_sha --commit "${options[--commit]}"
[[ -z ${options[--from-sha]-} ]] || full_sha --from-sha "${options[--from-sha]}"
if [[ -n ${options[--event]+set} ]]; then
  one_of --event "${options[--event]}" APPROVE REQUEST_CHANGES COMMENT
fi
if [[ -n ${options[--state]+set} ]]; then
  one_of --state "${options[--state]}" open closed
fi
if [[ -n ${options[--state-reason]+set} ]]; then
  one_of --state-reason "${options[--state-reason]}" completed not_planned duplicate reopened
fi
if [[ -n ${options[--maintainer-can-modify]+set} ]]; then
  one_of --maintainer-can-modify "${options[--maintainer-can-modify]}" true false
fi
if [[ -n ${options[--milestone]+set} && ${options[--milestone]} != none ]]; then
  positive --milestone "${options[--milestone]}"
fi
for option in --labels-json --assignees-json --reviewers-json --team-reviewers-json; do
  [[ -n ${options[${option}]+set} ]] || continue
  jq -e -n --arg value "${options[${option}]}" '
    $value | fromjson | type == "array"
    and all(.[]; type == "string" and length > 0 and (explode | all(. >= 32 and . != 127)))
  ' >/dev/null 2>&1 || fail 2 "${option} must be a JSON array of non-empty strings"
done
if [[ ${options[--body-file]-} == - && ${options[--comments-file]-} == - ]]; then
  fail 2 "only one of --body-file and --comments-file can read standard input"
fi

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# file は一度だけ読む。標準入力を payload の組立てと検証で二度読まない
read_input() {
  local option=$1 target=$2 source=${options[$1]}
  if [[ ${source} == - ]]; then
    cat >"${target}"
  else
    [[ -f ${source} && -r ${source} ]] || fail 2 "${option} is not a readable file: ${source}"
    cat -- "${source}" >"${target}"
  fi
}

has_body=false
if [[ -n ${options[--body-file]-} ]]; then
  read_input --body-file "${work}/body"
  has_body=true
  if ! grep -q '[^[:space:]]' "${work}/body"; then
    case ${operation} in
      comment | comment-edit | review-reply | review) fail 2 "${operation} needs a non-blank body" ;;
      *) ;;
    esac
  fi
fi
if [[ ${operation} == review && ${options[--event]} != APPROVE && ${has_body} == false ]]; then
  fail 2 "a ${options[--event]} review needs --body-file"
fi

has_comments=false
if [[ -n ${options[--comments-file]-} ]]; then
  read_input --comments-file "${work}/comments"
  jq -e -s '
    length == 1 and (.[0] | type == "array" and length > 0 and all(.[];
      type == "object"
      and ((keys - ["path", "body", "line", "position", "side", "start_line", "start_side"]) | length) == 0
      and (.path | type) == "string" and (.path | length) > 0
      and (.body | type) == "string" and (.body | test("\\S"))
      and ((.line | type) == "number") != ((.position | type) == "number")
    ))
  ' "${work}/comments" >/dev/null 2>&1 ||
    fail 2 "--comments-file must be a non-empty JSON array of {path, body, line|position, side?, start_line?, start_side?}"
  has_comments=true
fi

# 指定した field だけを payload に入れる。省いた field は変えない
field_args=()
for option in --title --state --base; do
  if [[ -n ${options[${option}]+set} ]]; then
    field_args+=(--arg "${option#--}" "${options[${option}]}")
  fi
done
if [[ -n ${options[--state-reason]+set} ]]; then
  field_args+=(--arg state_reason "${options[--state-reason]}")
fi
if [[ -n ${options[--maintainer-can-modify]+set} ]]; then
  field_args+=(--argjson maintainer_can_modify "${options[--maintainer-can-modify]}")
fi
if [[ -n ${options[--milestone]+set} ]]; then
  if [[ ${options[--milestone]} == none ]]; then
    field_args+=(--argjson milestone null)
  else
    field_args+=(--argjson milestone "${options[--milestone]}")
  fi
fi
for option in --labels-json --assignees-json --reviewers-json --team-reviewers-json; do
  if [[ -n ${options[${option}]+set} ]]; then
    name=${option#--}
    name=${name%-json}
    field_args+=(--argjson "${name//-/_}" "${options[${option}]}")
  fi
done
if [[ ${has_body} == true ]]; then
  field_args+=(--rawfile body "${work}/body")
fi
if [[ ${has_comments} == true ]]; then
  field_args+=(--slurpfile comments "${work}/comments")
fi

number=${options[--number]-}
method=POST
case ${operation} in
  issue-create)
    endpoint="repos/${repo}/issues"
    jq -n "${field_args[@]}" '$ARGS.named | {title} + (if has("body") then {body} else {} end)' \
      >"${work}/payload"
    receipt='{id, number, html_url, state}'
    ;;
  issue-update)
    method=PATCH
    endpoint="repos/${repo}/issues/${number}"
    jq -n "${field_args[@]}" '$ARGS.named' >"${work}/payload"
    receipt='{id, number, html_url, state, state_reason, title, labels: [.labels[].name], assignees: [.assignees[].login], milestone: .milestone.number}'
    ;;
  comment)
    endpoint="repos/${repo}/issues/${number}/comments"
    jq -n "${field_args[@]}" '$ARGS.named' >"${work}/payload"
    receipt='{id, html_url}'
    ;;
  comment-edit)
    method=PATCH
    endpoint="repos/${repo}/issues/comments/${options[--comment-id]}"
    jq -n "${field_args[@]}" '$ARGS.named' >"${work}/payload"
    receipt='{id, html_url, updated_at}'
    ;;
  pr-create)
    endpoint="repos/${repo}/pulls"
    jq -n --arg head "${options[--head]}" --argjson draft "${draft}" "${field_args[@]}" '
      $ARGS.named | {title, head, base, draft} + (if has("body") then {body} else {} end)
    ' >"${work}/payload"
    receipt='{id, number, html_url, state, draft, head: {ref: .head.ref, sha: .head.sha}, base: {ref: .base.ref, sha: .base.sha}}'
    ;;
  pr-update)
    method=PATCH
    endpoint="repos/${repo}/pulls/${number}"
    jq -n "${field_args[@]}" '$ARGS.named' >"${work}/payload"
    receipt='{id, number, html_url, state, title, maintainer_can_modify, head: {ref: .head.ref, sha: .head.sha}, base: {ref: .base.ref, sha: .base.sha}}'
    ;;
  pr-reviewers)
    endpoint="repos/${repo}/pulls/${number}/requested_reviewers"
    jq -n "${field_args[@]}" '$ARGS.named' >"${work}/payload"
    receipt='{number, html_url, requested_reviewers: [.requested_reviewers[].login], requested_teams: [.requested_teams[].slug]}'
    ;;
  review)
    endpoint="repos/${repo}/pulls/${number}/reviews"
    jq -n --arg commit_id "${options[--commit]}" --arg event "${options[--event]}" \
      "${field_args[@]}" '$ARGS.named | if has("comments") then .comments |= .[0] else . end' \
      >"${work}/payload"
    receipt='{id, state, commit_id, html_url}'
    ;;
  review-reply)
    endpoint="repos/${repo}/pulls/${number}/comments/${options[--comment-id]}/replies"
    jq -n "${field_args[@]}" '$ARGS.named' >"${work}/payload"
    receipt='{id, in_reply_to_id, html_url}'
    ;;
  branch-create)
    # git/refs の作成は既存の ref を上書きしない。既存 branch の head は動かない
    endpoint="repos/${repo}/git/refs"
    jq -n --arg ref "refs/heads/${options[--branch]}" --arg sha "${options[--from-sha]}" \
      '$ARGS.named' >"${work}/payload"
    receipt='{ref, sha: .object.sha}'
    ;;
esac

[[ -r ${token_file} ]] || fail 3 "cannot read the token of account ${account}"
token=$(<"${token_file}")
[[ ${token} =~ ^[[:graph:]]+$ ]] || fail 3 "the token of account ${account} is empty or malformed"

# 利用者の gh 設定、active user、alias を読まない。token は環境変数で子へだけ渡し、引数に載せない
mkdir -p "${work}/config" "${work}/state" "${work}/cache" "${work}/data"
cd -- "${work}" || fail 3 "cannot enter the private gh directory; nothing was written"
run_gh() {
  GH_TOKEN=${token} GH_HOST=${gh_host} GH_CONFIG_DIR=${work}/config \
    XDG_CONFIG_HOME=${work}/config XDG_STATE_HOME=${work}/state \
    XDG_CACHE_HOME=${work}/cache XDG_DATA_HOME=${work}/data \
    GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 \
    GH_SPINNER_DISABLED=1 GH_TELEMETRY=false GH_PAGER=cat NO_COLOR=1 \
    "${gh}" "$@"
}

if ! actual_login=$(run_gh api user --jq .login); then
  fail 3 "could not confirm the login of account ${account}; nothing was written"
fi
[[ ${actual_login} == "${login}" ]] ||
  fail 3 "account ${account} authenticates as ${actual_login}, not ${login}; nothing was written"

if ! result=$(run_gh api --method "${method}" "${endpoint}" --input "${work}/payload" --jq "${receipt}"); then
  fail 4 "${operation} on ${repo} was sent as ${login} but not confirmed; read the target before any retry"
fi

jq -cn --arg account "${account}" --arg login "${login}" --arg operation "${operation}" \
  --argjson result "${result}" \
  '{account: $account, login: $login, operation: $operation, result: $result}' ||
  fail 4 "${operation} on ${repo} returned an unreadable receipt; read the target before any retry"
