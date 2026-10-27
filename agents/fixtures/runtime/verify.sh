#!/usr/bin/env bash
set -euo pipefail

fixture=$PWD/verify-fixture
home=$fixture/home
submodule_repo=$fixture/submodule-repo

skill_edit() {
  jq -nc --arg session "$1" --arg cwd "$home" --arg path "$2" \
    '{session_id:$session,cwd:$cwd,tool_name:"write",tool_input:{path:$path}}' |
    "$GATE" hook edit >/dev/null 2>&1
}

# argv の長さ制限を超える読取結果の jq --argjson 渡しは不可
skill_read_payload() {
  local extra=${5-} path relative resolved result_file=$fixture/skill-read-result.json
  [ -n "$extra" ] || extra='{}'
  printf '{}' >"$result_file"
  path=$(printf '%s' "$4" | jq -r '.path // .file_path // .filePath // empty')
  case $path in
  skill://*)
    relative=${path#skill://}
    case $relative in */*) ;; *) relative="$relative/SKILL.md" ;; esac
    path="$home/.omp/agent/skills/$relative"
    ;;
  /*) ;;
  *) path="$home/$path" ;;
  esac
  if [ -f "$path" ] && { [ "$3" = read ] || [ "$3" = Read ]; }; then
    resolved=$(realpath -e -- "$path")
    jq -nc --rawfile body "$path" --arg resolved "$resolved" --arg tool "$3" '
      ($body | gsub("\r\n?"; "\n") | sub("^\uFEFF"; "")) as $normalized |
      ($normalized | sub("\n$"; "")) as $display |
      ($normalized | split("\n") | if last == "" then .[:-1] else . end | length) as $lines |
      if $tool == "read" then
        {tool_result:{content:[{type:"text",text:$display}],
          details:{resolvedPath:$resolved,totalLines:$lines,
            displayContent:{text:$display,startLine:1,lineNumbers:[range(1;$lines+1)]}}}}
      else
        {tool_response:{type:"text",file:{filePath:$resolved,content:$display,
          numLines:$lines,startLine:1,totalLines:$lines}}}
      end' >"$result_file"
  fi
  jq -nc --arg session "$1" --arg event "$2" --arg tool "$3" \
    --arg cwd "$home" --argjson input "$4" --argjson extra "$extra" --slurpfile result "$result_file" \
    '($input | if $tool == "Read" and has("path") then .file_path = .path | del(.path) else . end) as $native |
      {session_id:$session,cwd:$cwd,hook_event_name:$event,tool_name:$tool,tool_input:$native} * $result[0] * $extra'
}

skill_read_event() {
  skill_read_payload "$@" | "$GATE" hook learn
}

expect_unread_skill() {
  if skill_edit "$1" /r/core/library.ts; then
    echo "gate accepted an incomplete Skill read: $1" >&2
    exit 1
  fi
}

edit_with_tmpdir() {
  local tmpdir=$1
  shift
  TMPDIR=$tmpdir skill_edit "$@"
}

expect_edit_allowed() {
  if ! edit_with_tmpdir "$1" "$2" "$3"; then
    echo "gate blocked an edit that needs no Skill: $3 (TMPDIR=$1 DOTFILES_AGENT_SESSION_ID=${DOTFILES_AGENT_SESSION_ID-unset})" >&2
    exit 1
  fi
}

expect_edit_blocked() {
  if edit_with_tmpdir "$1" "$2" "$3"; then
    echo "gate accepted an unread Skill path: $3 (TMPDIR=$1 DOTFILES_AGENT_SESSION_ID=${DOTFILES_AGENT_SESSION_ID-unset})" >&2
    exit 1
  fi
}

session_metadata() {
  jq -nc --arg session_id "$1" --argjson version "$2" --argjson owner_pid "$$" \
    '{version: $version, session_id: $session_id, client: "omp",
      project_id: ($session_id | split(".")[0]), boot_id: "0",
      owner_pid: $owner_pid, owner_start_time: "0"}'
}

check_isolated_scratch() {
  local sessions="$home/.cache/dotfiles-wsl/sessions" production="$fixture/scratch-production"
  local scratch_session=fixture-scratch.omp.4242.AbCd1234 forged_session=fixture-forged.omp.4243.AbCd1234
  local inside_session=fixture-inside-git.omp.4244.AbCd1234
  local scratch="$sessions/$scratch_session/tmp" forged="$sessions/$forged_session" inside="$sessions/$inside_session"
  local relative path tmpdir session variant
  local ui_read='{"path":"skill://ui-design"}'
  local -x DOTFILES_AGENT_SESSION_ID=$scratch_session

  mkdir -p "$scratch/reproduction" "$scratch/existing/runtimes/web" "$forged" "$inside/tmp" \
    "$fixture/forged-target" "$production/runtimes/web" "$production/surfaces/viewer" "$production/core"
  git init -q "$production"
  git init -q "$inside"
  printf 'export {};\n' >"$production/runtimes/web/App.tsx"
  printf 'export {};\n' >"$scratch/existing/runtimes/web/App.tsx"
  session_metadata "$scratch_session" 1 >"$sessions/$scratch_session/metadata.json"
  session_metadata "$forged_session" 1 >"$forged/metadata.json"
  session_metadata "$inside_session" 1 >"$inside/metadata.json"
  mkdir "$home/.cache/dotfiles-wsl/.git"
  expect_edit_allowed "$scratch" fixture-empty-git-marker "$scratch/runtimes/web/App.tsx"
  printf 'unrecognized metadata\n' >"$home/.cache/dotfiles-wsl/.git/config"
  expect_edit_blocked "$scratch" fixture-unknown-git-marker "$scratch/runtimes/web/App.tsx"
  rm "$home/.cache/dotfiles-wsl/.git/config"
  rmdir "$home/.cache/dotfiles-wsl/.git"

  for path in \
    "$scratch/reproduction/runtimes/web/App.tsx" \
    "$scratch/reproduction/surfaces/viewer/features/x.tsx" \
    "$scratch/reproduction/core/library.ts" \
    "$scratch/reproduction/b/domain/Invoice.cs" \
    "$scratch/reproduction/fixtures/surfaces/viewer/x.tsx" \
    "$scratch/reproduction/inner/../runtimes/web/Dotdot.tsx" \
    "$scratch/existing/runtimes/web/App.tsx" \
    ".cache/dotfiles-wsl/sessions/fixture-scratch.omp.4242.AbCd1234/tmp/relative/runtimes/web/App.tsx"; do
    expect_edit_allowed "$scratch" fixture-scratch-unread "$path"
  done
  ln -s "$scratch/reproduction" "$scratch/alias"
  expect_edit_allowed "$scratch" fixture-scratch-unread "$scratch/alias/runtimes/web/Aliased.tsx"
  ln -s "$scratch" "$fixture/scratch-spelling"
  expect_edit_allowed "$fixture/scratch-spelling" fixture-scratch-unread "$scratch/reproduction/runtimes/web/App.tsx"
  test -z "$(TMPDIR=$scratch "$GATE" skill --path "$scratch/reproduction/runtimes/web/App.tsx")"
  test "$(TMPDIR=$scratch "$GATE" skill --path "$production/runtimes/web/App.tsx")" = ui-design

  for tmpdir in "" "$fixture" "$home" "$sessions" "${scratch%/tmp}" "$scratch/reproduction"; do
    expect_edit_blocked "$tmpdir" fixture-scratch-foreign "$scratch/reproduction/runtimes/web/App.tsx"
  done
  ln -s "$fixture/forged-target" "$forged/tmp"
  DOTFILES_AGENT_SESSION_ID=$forged_session expect_edit_blocked "$forged/tmp" fixture-scratch-foreign "$fixture/forged-target/runtimes/web/App.tsx"
  DOTFILES_AGENT_SESSION_ID=$forged_session expect_edit_blocked "$forged/tmp" fixture-scratch-foreign "$forged/tmp/runtimes/web/App.tsx"
  DOTFILES_AGENT_SESSION_ID=$inside_session expect_edit_blocked "$inside/tmp" fixture-scratch-foreign "$inside/tmp/runtimes/web/App.tsx"
  for session in "$inside_session" ""; do
    DOTFILES_AGENT_SESSION_ID=$session expect_edit_blocked "$scratch" fixture-scratch-foreign "$scratch/reproduction/runtimes/web/App.tsx"
  done
  for variant in handmade malformed foreign-id version linked; do
    session=fixture-$variant.omp.4245.AbCd1234
    mkdir -p "$sessions/$session/tmp"
    case $variant in
    malformed) printf 'not json\n' >"$sessions/$session/metadata.json" ;;
    foreign-id) session_metadata "$scratch_session" 1 >"$sessions/$session/metadata.json" ;;
    version) session_metadata "$session" 2 >"$sessions/$session/metadata.json" ;;
    linked)
      session_metadata "$session" 1 >"$fixture/linked-metadata.json"
      ln -s "$fixture/linked-metadata.json" "$sessions/$session/metadata.json"
      ;;
    esac
    DOTFILES_AGENT_SESSION_ID=$session expect_edit_blocked "$sessions/$session/tmp" fixture-scratch-foreign \
      "$sessions/$session/tmp/runtimes/web/App.tsx"
  done

  for path in \
    "$production/runtimes/web/App.tsx" \
    "$production/runtimes/web/Created.tsx" \
    "$production/core/library.ts" \
    "$production/surfaces/viewer/fixtures/Page.ts" \
    "$production/runtimes/web/fixtures/App.tsx" \
    /r/core/fixtures/library.ts; do
    expect_edit_blocked "$scratch" fixture-production-unread "$path"
  done
  skill_read_event fixture-production-read PostToolUse read "$ui_read"
  expect_edit_allowed "$scratch" fixture-production-read "$production/runtimes/web/App.tsx"
  expect_edit_blocked "$scratch" fixture-production-read "$production/core/library.ts"
  skill_read_event fixture-scratch-partial PostToolUse read "$ui_read" '{"is_error":true}'
  expect_edit_blocked "$scratch" fixture-scratch-partial "$production/runtimes/web/App.tsx"
  expect_edit_allowed "$scratch" fixture-scratch-partial "$scratch/reproduction/runtimes/web/App.tsx"

  relative=$(realpath -m --relative-to="$scratch" "$production/runtimes/web/App.tsx")
  expect_edit_blocked "$scratch" fixture-traversal "$scratch/$relative"
  expect_edit_blocked "$scratch" fixture-traversal "$scratch/missing/../$relative"
  expect_edit_blocked "$scratch" fixture-traversal "$production/surfaces/viewer/tests/../Page.tsx"
  expect_edit_blocked "$scratch" fixture-traversal /r/surfaces/viewer/tests/../x.tsx
  ln -s "$production" "$scratch/production-link"
  ln -s "$production/runtimes/web/Pending.tsx" "$scratch/pending.tsx"
  ln -s "$production/core/library.ts" "$scratch/notes.md"
  for path in \
    "$scratch/production-link/runtimes/web/App.tsx" \
    "$scratch/production-link/runtimes/web/Created.tsx" \
    "$scratch/pending.tsx" \
    "$scratch/notes.md"; do
    expect_edit_blocked "$scratch" fixture-symlink "$path"
  done

  git init -q "$scratch/clone"
  mkdir "$scratch/linked"
  printf 'gitdir: %s\n' "$production/.git" >"$scratch/linked/.git"
  for path in \
    "$scratch/clone/runtimes/web/App.tsx" \
    "$scratch/clone/new/surfaces/viewer/x.tsx" \
    "$scratch/clone/core/library.ts" \
    "$scratch/linked/runtimes/web/App.tsx"; do
    expect_edit_blocked "$scratch" fixture-clone "$path"
  done
  skill_read_event fixture-clone-read PostToolUse read "$ui_read"
  expect_edit_allowed "$scratch" fixture-clone-read "$scratch/clone/runtimes/web/App.tsx"

  for path in \
    /r/surfaces/viewer/x.test.tsx \
    /r/surfaces/viewer/x.doubles.tsx \
    /r/tests/conformance/small/viewer.ts \
    "$production/surfaces/viewer/tests/small/Page.tsx"; do
    expect_edit_allowed "$fixture" fixture-test-paths "$path"
  done
}

check_skill_learning() {
  local source="$fixture/skill-source" deployed="$home/.omp/agent/skills"
  local body input session rejected status
  local -a design_paths=(
    /r/core/library.ts
    /r/core/b/application/ports/IFoo.cs
    /r/contracts/canonical/Order.cs
    /r/contracts/types.tsp
    /r/core/b/domain/OrderFailure.cs
    /r/core/b/errors/cause.ts
    /r/module.csproj
    /r/libs/shared/codec.ts
    /r/surfaces/cli/main.ts
  )
  mkdir -p "$source" "$deployed"
  cp -R "$CODEBASE_DESIGN_SOURCE" "$source/codebase-design"
  chmod -R u+w "$source/codebase-design"
  ln -s "$source/codebase-design" "$deployed/codebase-design"
  ln -s "$UI_DESIGN_SOURCE" "$deployed/ui-design"
  ln -s "$DOMAIN_MODELING_SOURCE" "$deployed/domain-modeling"
  body="$deployed/codebase-design/SKILL.md"

  test "$("$GATE" skill --path /r/surfaces/viewer/features/x/y.tsx)" = ui-design
  test "$("$GATE" skill --path /r/core/b/domain/Invoice.cs)" = domain-modeling
  for rejected in "${design_paths[@]}"; do
    test "$("$GATE" skill --path "$rejected")" = codebase-design
    if skill_edit fixture-unread "$rejected"; then
      echo "gate accepted an unread codebase-design path: $rejected" >&2
      exit 1
    fi
  done
  test -z "$("$GATE" skill --path /r/surfaces/viewer/x.test.tsx)"
  test -z "$("$GATE" skill --path /r/docs/note.md)"
  expect_unread_skill fixture-unread

  input=$(jq -nc --arg path "$body" '{path:$path}')
  for rejected in PreToolUse PostToolUseFailure ""; do
    session="fixture-event-${rejected:-missing}"
    skill_read_event "$session" "$rejected" read "$input"
    expect_unread_skill "$session"
  done
  skill_read_event fixture-result-error PostToolUse read "$input" '{"is_error":true}'
  expect_unread_skill fixture-result-error
  skill_read_event fixture-response-error PostToolUse Read "$input" '{"tool_response":{"error":"read failed"}}'
  expect_unread_skill fixture-response-error
  skill_read_event fixture-response-failed PostToolUse Read "$input" '{"tool_response":{"success":false}}'
  expect_unread_skill fixture-response-failed
  skill_read_event fixture-result-truncated PostToolUse read "$input" \
    '{"tool_result":{"details":{"truncation":{"truncated":true}}}}'
  expect_unread_skill fixture-result-truncated
  skill_read_event fixture-result-summary PostToolUse read "$input" \
    '{"tool_result":{"details":{"summary":{"lines":1,"elidedSpans":1,"elidedLines":2}}}}'
  expect_unread_skill fixture-result-summary
  skill_read_event fixture-result-output-cap PostToolUse read "$input" \
    '{"tool_result":{"details":{"meta":{"truncation":{"direction":"head","truncatedBy":"lines","totalLines":3,"totalBytes":80,"outputLines":1,"outputBytes":14}}}}}'
  expect_unread_skill fixture-result-output-cap
  skill_read_event fixture-result-columns PostToolUse read "$input" \
    '{"tool_result":{"details":{"meta":{"limits":{"columnTruncated":{"maxColumn":40,"unit":"chars"}}}}}}'
  expect_unread_skill fixture-result-columns
  skill_read_event fixture-result-page PostToolUse read "$input" \
    '{"tool_result":{"details":{"displayContent":{"lineNumbers":[1]}}}}'
  expect_unread_skill fixture-result-page
  skill_read_event fixture-result-body PostToolUse read "$input" \
    '{"tool_result":{"content":[{"type":"text","text":"different returned body"}],"details":{"displayContent":{"text":"different returned body"}}}}'
  expect_unread_skill fixture-result-body
  skill_read_event fixture-result-rendered PostToolUse read "$input" \
    '{"tool_result":{"content":[{"type":"text","text":"Only a notice was returned."}]}}'
  expect_unread_skill fixture-result-rendered
  cp "$body" "$fixture/other-code-skill.md"
  skill_read_event fixture-result-source PostToolUse read "$input" \
    "$(jq -nc --arg path "$fixture/other-code-skill.md" '{tool_result:{details:{resolvedPath:$path}}}')"
  expect_unread_skill fixture-result-source
  skill_read_event fixture-claude-token-cap PostToolUse Read "$input" \
    '{"tool_response":{"file":{"truncatedByTokenCap":true}}}'
  expect_unread_skill fixture-claude-token-cap
  skill_read_event fixture-claude-page PostToolUse Read "$input" \
    '{"tool_response":{"file":{"numLines":1}}}'
  expect_unread_skill fixture-claude-page
  skill_read_event fixture-claude-unchanged PostToolUse Read "$input" \
    '{"tool_response":{"type":"file_unchanged"}}'
  expect_unread_skill fixture-claude-unchanged
  skill_read_event fixture-claude-body PostToolUse Read "$input" \
    '{"tool_response":{"file":{"content":"different returned body"}}}'
  expect_unread_skill fixture-claude-body
  skill_read_event fixture-claude-source PostToolUse Read "$input" \
    "$(jq -nc --arg path "$fixture/other-code-skill.md" '{tool_response:{file:{filePath:$path}}}')"
  expect_unread_skill fixture-claude-source
  skill_read_event fixture-write-event PostToolUse write "$input"
  expect_unread_skill fixture-write-event

  for rejected in \
    "$deployed/codebase-design/nonexistent.md" \
    "$deployed/codebase-design/DEEPENING.md" \
    'skill://codebase-design/DEEPENING.md' \
    "$body:1-2" 'skill://codebase-design:1-2' 'skill://codebase-design/SKILL.md:raw' \
    "$deployed/codebase-design" "$source/codebase-design/SKILL.md"; do
    session="fixture-path-$(printf '%s' "$rejected" | sha256sum | cut -d ' ' -f 1)"
    input=$(jq -nc --arg path "$rejected" '{path:$path}')
    skill_read_event "$session" PostToolUse read "$input"
    expect_unread_skill "$session"
  done
  input=$(jq -nc --arg path "$body" '{file_path:$path,offset:1}')
  skill_read_event fixture-offset PostToolUse Read "$input"
  expect_unread_skill fixture-offset
  input=$(jq -nc --arg path "$body" '{file_path:$path,limit:2}')
  skill_read_event fixture-limit PostToolUse Read "$input"
  expect_unread_skill fixture-limit
  input=$(jq -nc --arg path "$deployed/codebase-design/nonexistent.md" '{path:$path}')
  skill_read_event fixture-edit-bypass PreToolUse write "$input"
  skill_edit fixture-edit-bypass "$deployed/codebase-design/nonexistent.md"
  expect_unread_skill fixture-edit-bypass
  skill_edit fixture-edit-body-bypass "$body"
  expect_unread_skill fixture-edit-body-bypass

  mkdir -p "$home/.cache/dotfiles-wsl/verification/sessions/fixture-old-marker/skills"
  : >"$home/.cache/dotfiles-wsl/verification/sessions/fixture-old-marker/skills/codebase-design"
  expect_unread_skill fixture-old-marker

  cat "$body" >/dev/null
  input=$(jq -nc --arg path "$body" '{path:$path}')
  skill_read_event fixture-body PostToolUse read "$input"
  for rejected in "${design_paths[@]}"; do
    skill_edit fixture-body "$rejected"
  done
  input=$(jq -nc --arg path "$body" '{file_path:$path}')
  skill_read_event fixture-claude PostToolUse Read "$input" '{"tool_response":{"type":"text"}}'
  skill_edit fixture-claude /r/core/library.ts
  for rejected in 'skill://codebase-design' 'skill://codebase-design/SKILL.md' \
    '.omp/agent/skills/codebase-design/SKILL.md'; do
    session="fixture-canonical-$(printf '%s' "$rejected" | sha256sum | cut -d ' ' -f 1)"
    input=$(jq -nc --arg path "$rejected" '{path:$path}')
    skill_read_event "$session" PostToolUse read "$input"
    skill_edit "$session" /r/core/library.ts
  done
  printf '\nChanged fixture body digest.\n' >>"$source/codebase-design/SKILL.md"
  expect_unread_skill fixture-body
  expect_unread_skill fixture-claude
  cat "$body" >/dev/null
  input=$(jq -nc --arg path "$body" '{path:$path}')
  skill_read_event fixture-body PostToolUse read "$input"
  skill_edit fixture-body /r/core/library.ts

  if "$GATE" teach --session fixture-skills --path /r/surfaces/viewer/x.tsx >/dev/null 2>&1; then
    echo 'gate let an unread discipline be edited' >&2
    exit 1
  fi
  "$GATE" learned --session fixture-skills --path ui-design
  "$GATE" teach --session fixture-skills --path /r/surfaces/viewer/x.tsx >/dev/null
  if "$GATE" teach --session fixture-skills --path /r/core/b/domain/Invoice.cs >/dev/null 2>&1; then
    echo 'gate accepted one discipline as a licence for another' >&2
    exit 1
  fi
  "$GATE" learned --session fixture-skills --path codebase-design
  for rejected in "${design_paths[@]}"; do
    "$GATE" teach --session fixture-skills --path "$rejected" >/dev/null
  done
  if "$GATE" teach --session fixture-skills --path /r/core/b/domain/Invoice.cs >/dev/null 2>&1; then
    echo 'gate accepted codebase-design as a licence for domain-modeling' >&2
    exit 1
  fi
  rm "$source/codebase-design/SKILL.md"
  set +e
  "$GATE" learned --session fixture-empty-skill --path codebase-design >/dev/null 2>&1
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo 'trusted learned command accepted a missing canonical Skill body' >&2
    exit 1
  fi
  input='{"path":"skill://codebase-design"}'
  skill_read_event fixture-missing-body PostToolUse read "$input"
  if skill_edit fixture-missing-body /r/module.csproj; then
    echo 'gate accepted a successful event without an existing canonical body' >&2
    exit 1
  fi
  cp "$CODEBASE_DESIGN_SOURCE/SKILL.md" "$source/codebase-design/SKILL.md"

  "$CUSTOM_SKILL_ROOT_GATE" teach --session fixture-custom-root --path /r/surfaces/viewer/x.tsx >/dev/null
  body="$home/.local/share/fixture adapter/procedures/ui-design/SKILL.md"
  mkdir -p "$(dirname "$body")"
  cp "$UI_DESIGN_SOURCE/SKILL.md" "$body"
  if "$CUSTOM_SKILL_ROOT_GATE" teach --session fixture-custom-root --path /r/surfaces/viewer/x.tsx >/dev/null 2>&1; then
    echo 'gate ignored the contract skill root' >&2
    exit 1
  fi
  cat "$body" >/dev/null
  input=$(jq -nc --arg path "$body" '{path:$path}')
  GATE="$CUSTOM_SKILL_ROOT_GATE" skill_read_event fixture-custom-root PostToolUse read "$input"
  "$CUSTOM_SKILL_ROOT_GATE" teach --session fixture-custom-root --path /r/surfaces/viewer/x.tsx >/dev/null
  check_isolated_scratch
}

large_read_teach() {
  "$CUSTOM_SKILL_ROOT_GATE" teach --session "$1" --path /r/surfaces/viewer/x.tsx >/dev/null 2>&1
}

large_read_learn() {
  jq -c --arg session "$2" ".session_id = \$session | $3" "$1" | "$CUSTOM_SKILL_ROOT_GATE" hook learn
}

expect_large_read_learned() {
  large_read_learn "$1" "$2" .
  if ! large_read_teach "$2"; then
    echo "gate refused a complete Skill read beyond the argument limit: $2" >&2
    exit 1
  fi
}

expect_large_read_refused() {
  large_read_learn "$1" "$2" "$3"
  if large_read_teach "$2"; then
    echo "gate accepted an incomplete or altered Skill read beyond the argument limit: $2" >&2
    exit 1
  fi
}

check_large_read_proof() {
  local body="$home/.local/share/fixture adapter/procedures/ui-design/SKILL.md"
  local omp=$fixture/large-read-omp.json claude=$fixture/large-read-claude.json input
  local cut='.[:-2000]' alter='(.[:100000] + "§" + .[100001:])'
  chmod u+w "$body"
  seq -f 'Large discipline line %g keeps the whole read beyond one argument.' 1 4000 >>"$body"
  test "$(wc -c <"$body")" -gt 131072
  input=$(jq -nc --arg path "$body" '{path:$path}')
  skill_read_payload large PostToolUse read "$input" >"$omp"
  skill_read_payload large PostToolUse Read "$input" >"$claude"
  test "$(wc -c <"$omp")" -gt 262144
  test "$(wc -c <"$claude")" -gt 131072

  expect_large_read_learned "$omp" large-omp-complete
  expect_large_read_learned "$claude" large-claude-complete

  expect_large_read_refused "$omp" large-omp-truncated "
    (.tool_result.details.displayContent.text | $cut) as \$shown
    | (\$shown | split(\"\\n\") | length) as \$lines
    | .tool_result.content[0].text = \$shown
    | .tool_result.details.displayContent = {text: \$shown, startLine: 1, lineNumbers: [range(1; \$lines + 1)]}
    | .tool_result.details.totalLines = \$lines"
  expect_large_read_refused "$omp" large-omp-altered \
    ".tool_result.content[0].text |= $alter | .tool_result.details.displayContent.text |= $alter"
  expect_large_read_refused "$omp" large-omp-altered-rendered ".tool_result.content[0].text |= $alter"
  expect_large_read_refused "$omp" large-omp-altered-display ".tool_result.details.displayContent.text |= $alter"
  expect_large_read_refused "$omp" large-omp-missing 'del(.tool_result.details.displayContent)'
  expect_large_read_refused "$omp" large-omp-no-result 'del(.tool_result)'
  expect_large_read_refused "$claude" large-claude-truncated ".tool_response.file.content |= $cut"
  expect_large_read_refused "$claude" large-claude-altered ".tool_response.file.content |= $alter"
  expect_large_read_refused "$claude" large-claude-missing 'del(.tool_response.file)'

  printf 'Changed after the read.\n' >>"$body"
  if large_read_teach large-omp-complete; then
    echo 'gate kept a large Skill read after the body changed' >&2
    exit 1
  fi
  expect_large_read_refused "$omp" large-omp-replayed .
}

stall_litter() {
  find "$home/.cache/dotfiles-wsl/verification" -mindepth 1 -name '.*' -print | sort
}

stall_receipt_count() {
  find "$home/.cache/dotfiles-wsl/verification" -type f -name '*.verified' -print | wc -l
}

declare_budget() {
  printf '{"version":1,"verify":{"seconds":%s}}\n' "$2" >"$1/verification-budget.json"
}

t1_repository() {
  git init -q "$1"
  printf 'scripts.verify.exec = "true";\n' >"$1/devenv.nix"
  declare_budget "$1" "$2"
  git -C "$1" add devenv.nix verification-budget.json
  git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
}

expect_closed_gate() {
  if "$GATE" check --repo "$1" >/dev/null 2>&1; then
    echo "gate accepted a T1 that did not finish inside its budget: $2" >&2
    exit 1
  fi
}

expect_open_gate() {
  if ! "$GATE" check --repo "$1" >/dev/null 2>&1; then
    echo "gate closed on a tree that a completed T1 verified: $2" >&2
    exit 1
  fi
}

# 別 session の孫が検証の返却時点でまだ動くかを判定する観測
# 引数 $1: 当該 fixture が起動した Linux process 番号
# 戻り値: 読取可能な非 zombie process なら0でそれ以外は1
# 返却後の待ち直しは別 session の孫の回収を返却時点で検証できないため不可
process_alive() {
  local proc_stat
  proc_stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  [[ ${proc_stat##*) } != [ZX]* ]]
}

# 終了待機前の観測情報による元 process の消滅判定
# 引数 $1: 観測済みの Linux process 番号
# 引数 $2: 同じ boot 内で観測した開始 tick
# 戻り値: 観測不能か開始 tick の変化で0となる判定結果
# zombie は回収前のため state だけによる完了判定は不可
# pid の再利用があるため pid だけによる寿命の照合は不可
process_reaped() {
  local proc_stat
  local -a proc_fields
  proc_stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
  read -r -a proc_fields <<<"${proc_stat##*) }"
  [ "${proc_fields[19]}" != "$2" ]
}

expect_budget_refused() {
  local repository=$1 name=$2 status=0 litter receipts
  litter=$(stall_litter)
  receipts=$(stall_receipt_count)
  rm -f "$fixture/refused-runs"
  (cd "$repository" && PATH="$fixture/budget-bin:$PATH" DEADLINE_RUNS=$fixture/refused-runs \
    "$VERIFY" -- devenv shell -- verify) 2>"$fixture/refused-stderr" || status=$?
  if [ "$status" -ne 78 ]; then
    echo "T1 with a $name budget exited $status instead of the configuration status" >&2
    exit 1
  fi
  if [[ $(<"$fixture/refused-stderr") != *verification-budget.json* ]]; then
    echo "T1 with a $name budget did not name the declaration it refused" >&2
    exit 1
  fi
  if [ -e "$fixture/refused-runs" ]; then
    echo "T1 with a $name budget ran the entry" >&2
    exit 1
  fi
  expect_closed_gate "$repository" "$name budget"
  if [ "$(stall_litter)" != "$litter" ] || [ "$(stall_receipt_count)" != "$receipts" ]; then
    echo "T1 with a $name budget left receipts or temporary state behind" >&2
    exit 1
  fi
}
check_metadata_snapshot_boundary() (
  local repository name status receipts litter
  export HOME=$home BOUNDARY_JQ
  BOUNDARY_JQ=$(command -v jq)
  mkdir -p "$home/.cache/dotfiles-wsl/verification" "$fixture/snapshot-bin"
  printf '#!%s\nset -euo pipefail\nprintf run >"$SNAPSHOT_RUN"\n(sleep 3; touch "$SNAPSHOT_LATE") &\nwait\n' \
    "$BASH" >"$fixture/snapshot-bin/nix"
  chmod +x "$fixture/snapshot-bin/nix"
  export PATH="$fixture/snapshot-bin:$PATH"
  jq() {
    local result status=0
    if [[ " $* " == *" --arg stage verify "* && ! -e $SNAPSHOT_PROOF ]]; then
      result=$("$BOUNDARY_JQ" "$@") || status=$?
      if [ "$status" -eq 0 ]; then
        case $SNAPSHOT_CHANGE in
          removed-entry) printf '{"version":1,"frontend":"nix","entries":[],"verify":{"seconds":2}}\n' >"$SNAPSHOT_METADATA" ;;
          deleted) rm -- "$SNAPSHOT_METADATA" ;;
          malformed) printf 'not json\n' >"$SNAPSHOT_METADATA" ;;
        esac
        printf after-budget >"$SNAPSHOT_PROOF"
      fi
      printf '%s\n' "$result"
      return "$status"
    fi
    "$BOUNDARY_JQ" "$@"
  }
  export -f jq
  for name in removed-entry deleted malformed; do
    repository=$fixture/snapshot-$name
    git init -q "$repository"
    printf '{ outputs = { self }: {}; }\n' >"$repository/flake.nix"
    printf '{"version":1,"frontend":"nix","entries":["verify"],"verify":{"seconds":2}}\n' \
      >"$repository/verification-budget.json"
    git -C "$repository" add flake.nix verification-budget.json
    git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
    export SNAPSHOT_METADATA=$repository/verification-budget.json SNAPSHOT_CHANGE=$name
    export SNAPSHOT_PROOF=$fixture/snapshot-$name-proof SNAPSHOT_RUN=$fixture/snapshot-$name-run
    export SNAPSHOT_LATE=$fixture/snapshot-$name-late
    receipts=$(stall_receipt_count)
    litter=$(stall_litter)
    status=0
    (cd "$repository" && timeout 15 "$VERIFY" -- nix run --no-write-lock-file .#verify) \
      2>"$fixture/snapshot-$name-stderr" || status=$?
    if [ "$status" -ne 124 ]; then
      echo "canonical T1 after a $name metadata edit exited $status instead of retaining its captured deadline" >&2
      exit 1
    fi
    test "$(cat "$SNAPSHOT_PROOF")" = after-budget
    test "$(cat "$SNAPSHOT_RUN")" = run
    sleep 4
    test ! -e "$SNAPSHOT_LATE"
    test "$(stall_receipt_count)" = "$receipts"
    test "$(stall_litter)" = "$litter"
    git -C "$repository" restore --worktree -- verification-budget.json
    expect_closed_gate "$repository" "$name snapshot race"
  done
  printf '#!%s\nprintf focused >"$SNAPSHOT_RUN"\n' "$BASH" >"$fixture/snapshot-bin/focused"
  chmod +x "$fixture/snapshot-bin/focused"
  for name in missing invalid-budget malformed; do
    case $name in
      missing) rm -- "$SNAPSHOT_METADATA" ;;
      invalid-budget) printf '{"version":1,"frontend":"nix","entries":["verify"],"verify":{"seconds":0}}\n' >"$SNAPSHOT_METADATA" ;;
      malformed) printf 'not json\n' >"$SNAPSHOT_METADATA" ;;
    esac
    rm -f "$SNAPSHOT_RUN"
    status=0
    (cd "$repository" && timeout 15 "$VERIFY" -- nix run --no-write-lock-file .#verify) \
      2>"$fixture/snapshot-initial-$name-stderr" || status=$?
    if [ "$status" -ne 78 ]; then
      echo "canonical T1 with $name metadata exited $status instead of refusing configuration" >&2
      exit 1
    fi
    test ! -e "$SNAPSHOT_RUN"
    [[ $(<"$fixture/snapshot-initial-$name-stderr") == *verification-budget.json* ]]
    (cd "$repository" && "$VERIFY" -- "$fixture/snapshot-bin/focused")
    test "$(cat "$SNAPSHOT_RUN")" = focused
    test "$(stall_receipt_count)" = "$receipts"
    git -C "$repository" restore --worktree -- verification-budget.json
    expect_closed_gate "$repository" "$name metadata refusal"
  done
)


check_receipt_boundaries() {
  local control=$fixture/stall-control previous=$PWD
  local name utility when pattern initial_runs retry_runs repository litter_before receipts_before status wrapper
  local proof limit foreign process_stat boot_id
  local denial_trace
  local -a process_fields
  local -x DOTFILES_AGENT_TEST_STALL=$control
  local -x STALL_RUNS=
  local -x PATH="$fixture/stall-bin:$PATH"

  mkdir "$fixture/stall-bin"
  cat >"$fixture/stall-bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count=0
test ! -e "$STALL_RUNS" || count=$(cat "$STALL_RUNS")
printf '%s\n' "$((count + 1))" >"$STALL_RUNS"
SCRIPT
  chmod +x "$fixture/stall-bin/devenv"
  sed -i "1c#!$BASH" "$fixture/stall-bin/devenv"

  while read -r name utility when pattern initial_runs retry_runs <&3; do
    printf 'receipt boundary: %s\n' "$name" >&2
    repository=$fixture/stall-$name
    t1_repository "$repository" 3
    STALL_RUNS=$fixture/stall-$name-runs
    litter_before=$(stall_litter)
    receipts_before=$(stall_receipt_count)
    cd "$repository"

    printf '%s %s %s\n' "$utility" "$when" "$pattern" >"$control"
    rm -f "$control.ready"
    set +e
    "$STALLING_VERIFY" -- devenv shell -- verify
    status=$?
    set -e
    rm -f "$control"
    if [ "$status" -ne 124 ]; then
      echo "T1 stopped at $name exited $status instead of the deadline status" >&2
      exit 1
    fi
    if [ ! -s "$control.ready" ]; then
      echo "T1 never reached the stage to stop at: $name" >&2
      exit 1
    fi
    test "$(cat "$STALL_RUNS" 2>/dev/null || printf 0)" = "$initial_runs"
    expect_closed_gate "$repository" "$name"
    if [ "$(stall_litter)" != "$litter_before" ] || [ "$(stall_receipt_count)" != "$receipts_before" ]; then
      echo "T1 stopped at $name left receipts or temporary state behind" >&2
      printf 'temporary state before:\n%s\nafter:\n%s\nreceipts before=%s after=%s\n' \
        "$litter_before" "$(stall_litter)" "$receipts_before" "$(stall_receipt_count)" >&2
      exit 1
    fi

    "$STALLING_VERIFY" -- devenv shell -- verify
    expect_open_gate "$repository" "retry after $name"
    if [ "$(cat "$STALL_RUNS")" != "$retry_runs" ]; then
      echo "retry after $name ran the command $(cat "$STALL_RUNS") times instead of $retry_runs" >&2
      exit 1
    fi
    test "$(stall_litter)" = "$litter_before"
    test "$(stall_receipt_count)" = "$((receipts_before + 1))"
  done 3<<'SCENARIOS'
staged-after mv after */.pending.* 0 1
witness-cleanup-after rm after */.witness.* 0 1
publish-before mv before *.verified 1 2
publish-after mv after *.verified 1 2
SCENARIOS

  while read -r name utility when pattern initial_runs retry_runs <&4; do
    printf 'receipt cancellation: %s\n' "$name" >&2
    repository=$fixture/stall-$name
    t1_repository "$repository" 60
    STALL_RUNS=$fixture/stall-$name-runs
    litter_before=$(stall_litter)
    receipts_before=$(stall_receipt_count)
    cd "$repository"
    printf '%s %s %s\n' "$utility" "$when" "$pattern" >"$control"
    rm -f "$control.ready"
    "$STALLING_VERIFY" -- devenv shell -- verify &
    wrapper=$!
    for _ in $(seq 1 200); do
      [ ! -s "$control.ready" ] || break
      sleep 0.05
    done
    if [ ! -s "$control.ready" ]; then
      kill -KILL "$wrapper"
      echo "T1 never reached the stage to cancel at: $name" >&2
      exit 1
    fi
    expect_closed_gate "$repository" "$name while publication is still running"
    kill -TERM "$wrapper"
    set +e
    wait "$wrapper"
    status=$?
    set -e
    rm -f "$control"
    if [ "$status" -eq 0 ]; then
      echo "a T1 cancelled at $name reported success" >&2
      exit 1
    fi
    test "$(cat "$STALL_RUNS" 2>/dev/null || printf 0)" = "$initial_runs"
    expect_closed_gate "$repository" "$name"
    if [ "$(stall_litter)" != "$litter_before" ] || [ "$(stall_receipt_count)" != "$receipts_before" ]; then
      echo "a T1 cancelled at $name left receipts or temporary state behind" >&2
      exit 1
    fi
    "$STALLING_VERIFY" -- devenv shell -- verify
    expect_open_gate "$repository" "retry after $name"
    test "$(cat "$STALL_RUNS")" = "$retry_runs"
    test "$(stall_litter)" = "$litter_before"
    test "$(stall_receipt_count)" = "$((receipts_before + 1))"
  done 4<<'SCENARIOS'
cancel-staged mv after */.pending.* 0 1
cancel-published mv after *.verified 1 2
SCENARIOS

  for name in late-source capture-source; do
    repository=$fixture/stall-$name
    git init -q "$repository"
    printf '.PHONY: verify\nverify:\n\tprintf old >> ../%s-result\n' "$name" >"$repository/Makefile"
    declare_budget "$repository" 60
    git -C "$repository" add Makefile verification-budget.json
    git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
    litter_before=$(stall_litter)
    cd "$repository"
    if [ "$name" = late-source ]; then pattern='*.verified'; else pattern='*/.pending.*'; fi
    printf 'mv after %s\n' "$pattern" >"$control"
    rm -f "$control.ready" "$control.release"
    "$STALLING_VERIFY" -- make verify &
    wrapper=$!
    for _ in $(seq 1 200); do
      [ ! -s "$control.ready" ] || break
      sleep 0.05
    done
    if [ ! -s "$control.ready" ]; then
      kill -TERM "$wrapper"
      wait "$wrapper" || true
      echo "T1 never reached the source replacement boundary: $name" >&2
      exit 1
    fi
    printf '.PHONY: verify\nverify:\n\tprintf new >> ../%s-result\n' "$name" >Makefile
    touch "$control.release"
    wait "$wrapper"
    rm -f "$control" "$control.ready" "$control.release"
    expect_closed_gate "$repository" "$name unchecked replacement"
    if [ "$name" = late-source ]; then
      test "$(cat "$fixture/$name-result")" = old
    else
      test "$(cat "$fixture/$name-result")" = new
      printf '.PHONY: verify\nverify:\n\tprintf old >> ../%s-result\n' "$name" >Makefile
      expect_closed_gate "$repository" "$name discarded capture"
      printf '.PHONY: verify\nverify:\n\tprintf new >> ../%s-result\n' "$name" >Makefile
    fi
    "$STALLING_VERIFY" -- make verify
    expect_open_gate "$repository" "$name checked replacement"
    if [ "$name" = late-source ]; then
      test "$(cat "$fixture/$name-result")" = oldnew
    else
      test "$(cat "$fixture/$name-result")" = newnew
    fi
    test "$(stall_litter)" = "$litter_before"
  done

  for name in partial-marker producer-identity; do
    repository=$fixture/stall-$name
    git init -q "$repository"
    printf '.PHONY: verify\nverify:\n\tprintf once >> ../%s-result\n' "$name" >"$repository/Makefile"
    declare_budget "$repository" 60
    git -C "$repository" add Makefile verification-budget.json
    git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
    cd "$repository"
    if [ "$name" = partial-marker ]; then
      printf 'mv after *.verified\n' >"$control"
      rm -f "$control.ready" "$control.release"
    fi
    "$STALLING_VERIFY" -- make verify &
    wrapper=$!
    if [ "$name" = partial-marker ]; then
      for _ in $(seq 1 200); do
        [ ! -s "$control.ready" ] || break
        sleep 0.05
      done
      if [ ! -s "$control.ready" ]; then
        kill -TERM "$wrapper"
        wait "$wrapper" || true
        echo 'T1 never reached the partial completion boundary' >&2
        exit 1
      fi
      proof=$(find "$home/.cache/dotfiles-wsl/verification" -type f -name "*.$wrapper.verified")
      limit=$(($(stat -c %s "$proof") + 14))
      prlimit --pid "$wrapper" --fsize="$limit:"
      touch "$control.release"
      status=0
      wait "$wrapper" || status=$?
      rm -f "$control" "$control.ready" "$control.release"
      test "$status" -ne 0
      expect_closed_gate "$repository" 'failed partial completion'
      test ! -e "$proof"
      "$STALLING_VERIFY" -- make verify &
      wait "$!"
    else
      wait "$wrapper"
    fi
    expect_open_gate "$repository" "$name completed run"
    # 成功した走行を再利用しないため、失敗した完了記録の後の再試行は command を実行し直す
    if [ "$name" = partial-marker ]; then
      test "$(cat "$fixture/$name-result")" = onceonce
    else
      test "$(cat "$fixture/$name-result")" = once
    fi

    if [ "$name" = producer-identity ]; then
      proof=$(find "$home/.cache/dotfiles-wsl/verification" -type f -name "*.$wrapper.verified")
      truncate -s -1 "$proof"
      expect_closed_gate "$repository" 'unterminated completion marker'
      printf '\n' >>"$proof"
      expect_open_gate "$repository" 'restored complete marker'
      (
        sleep 60 &
        foreign=$!
        trap 'kill "$foreign" 2>/dev/null || true; wait "$foreign" 2>/dev/null || true' EXIT
        mv -- "$proof" "${proof%.*.verified}.$foreign.verified"
        proof=${proof%.*.verified}.$foreign.verified
        expect_open_gate "$repository" 'modeled reused producer PID'
        status=0
        strace -f -qq -e trace=openat -P "/proc/$foreign/stat" \
          -e inject=openat:error=EACCES -o "$fixture/producer-stat-denial.log" \
          "$GATE" check --repo "$repository" >/dev/null 2>&1 || status=$?
        denial_trace=$(<"$fixture/producer-stat-denial.log")
        if [ "$status" -ne 1 ] \
          || ! [[ $denial_trace == *"/proc/$foreign/stat"*EACCES*"(INJECTED)"* ]]; then
          echo 'gate did not reject a denied producer identity read' >&2
          exit 1
        fi
        expect_open_gate "$repository" 'recovered producer identity read'
        process_stat=$(<"/proc/$foreign/stat")
        read -r -a process_fields <<<"${process_stat##*) }"
        sed -i "s/^producer_start_time=.*/producer_start_time=${process_fields[19]}/" "$proof"
        expect_closed_gate "$repository" 'complete receipt with matching live producer'
        IFS= read -r boot_id </proc/sys/kernel/random/boot_id
        if [ "$boot_id" = 00000000-0000-0000-0000-000000000000 ]; then
          boot_id=11111111-1111-1111-1111-111111111111
        else
          boot_id=00000000-0000-0000-0000-000000000000
        fi
        sed -i \
          -e "s/^boot_id=.*/boot_id=$boot_id/" \
          -e "s/^producer_start_time=.*/producer_start_time=${process_fields[19]}/" "$proof"
        expect_open_gate "$repository" 'modeled previous boot producer'
      )
    fi
  done

  name=survivor
  repository=$fixture/stall-$name
  t1_repository "$repository" 3
  STALL_RUNS=$fixture/stall-$name-runs
  litter_before=$(stall_litter)
  receipts_before=$(stall_receipt_count)
  cd "$repository"
  "$STALLING_VERIFY" -- devenv shell -- verify
  expect_open_gate "$repository" "$name completed run"
  test "$(stall_receipt_count)" = "$((receipts_before + 1))"
  printf 'mv after *.verified\n' >"$control"
  rm -f "$control.ready"
  set +e
  "$STALLING_VERIFY" -- devenv shell -- verify
  status=$?
  set -e
  rm -f "$control"
  if [ "$status" -ne 124 ] || [ ! -s "$control.ready" ]; then
    echo "the second T1 on the same tree was not stopped during publication: $status" >&2
    exit 1
  fi
  expect_open_gate "$repository" "$name earlier completed receipt"
  test "$(stall_receipt_count)" = "$((receipts_before + 1))"
  "$STALLING_VERIFY" -- devenv shell -- verify
  "$STALLING_VERIFY" -- devenv shell -- verify
  expect_open_gate "$repository" "$name repeated runs"
  # 公開で止めた二回目も含め、各走行は command を実行する
  test "$(cat "$STALL_RUNS")" = 4
  test "$(stall_receipt_count)" = "$((receipts_before + 1))"
  test "$(stall_litter)" = "$litter_before"

  cd "$previous"
}

# 宣言した入口でない呼び出しは、成功を保存せず毎回 command を実行する。
# 外部の状態を観測する command が、repository と環境と argv の一致だけで省かれてはならない。
check_wrapper_runs_every_time() {
  local repository=$fixture/runs-every-time external=$fixture/external-state
  local counter=$fixture/runs-every-time-count status output
  mkdir "$repository"
  git init -q "$repository"
  git -C "$repository" config user.name fixture
  git -C "$repository" config user.email fixture@example.invalid
  cat >"$repository/observe.sh" <<'SCRIPT'
read -r state <"$EXTERNAL_STATE"
printf 'observed=%s\n' "$state"
test "$state" = healthy
SCRIPT
  git -C "$repository" add observe.sh
  git -C "$repository" commit -qm initial
  printf 'healthy\n' >"$external"
  output=$(cd "$repository" && EXTERNAL_STATE=$external "$VERIFY" -- "$BASH" observe.sh)
  [ "$output" = observed=healthy ]
  printf 'unhealthy\n' >"$external"
  status=0
  output=$(cd "$repository" && EXTERNAL_STATE=$external "$VERIFY" -- "$BASH" observe.sh) || status=$?
  if [ "$status" -ne 1 ] || [ "$output" != observed=unhealthy ]; then
    echo "verify reused a success for a command whose external state changed: $status $output" >&2
    exit 1
  fi

  (cd "$repository" && COUNT=$counter "$VERIFY" -- "$fixture/check" first)
  (cd "$repository" && COUNT=$counter "$VERIFY" -- "$fixture/check" first)
  test "$(cat "$counter")" = 2
  status=0
  (cd "$repository" && COUNT=$counter CHECK_STATUS=7 "$VERIFY" -- "$fixture/check" first) || status=$?
  test "$status" -eq 7
  test "$(cat "$counter")" = 3

  # stdin、argv、stdout、stderr、終了 status は command へも呼び出し側へもそのまま届く
  status=0
  printf 'input\n' | (cd "$repository" && "$VERIFY" -- "$BASH" -c 'cat; printf "%s|" "$@" >&2; exit 3' _ 'a b' '') \
    >"$fixture/stdio-stdout" 2>"$fixture/stdio-stderr" || status=$?
  test "$status" -eq 3
  test "$(<"$fixture/stdio-stdout")" = input
  test "$(<"$fixture/stdio-stderr")" = 'a b||'

  # git の外でも、同じ呼び出しを保存した成功で省かない
  mkdir "$fixture/outside"
  (cd "$fixture/outside" && COUNT=$fixture/outside-count "$VERIFY" -- "$fixture/check" outside)
  (cd "$fixture/outside" && COUNT=$fixture/outside-count "$VERIFY" -- "$fixture/check" outside)
  test "$(cat "$fixture/outside-count")" = 2
}

# T1 の command の差し替え。slot は制御 file が許すまで走り続け、pass は何もせず、mutate は木を触る
slot_bin=$fixture/slot-bin
pass_bin=$fixture/pass-bin
mutate_bin=$fixture/mutate-bin

slot_commands() {
  mkdir -p "$slot_bin" "$pass_bin" "$mutate_bin"
  export PASS_LOG=$fixture/pass-log
  : >>"$PASS_LOG"
  cat >"$slot_bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'start %s %s\n' "$SLOT_NAME" "$(<tracked)" >>"$SLOT_LOG"
printf '%s\n' "$$" >"$SLOT_DIR/$SLOT_NAME.pid"
: >"$SLOT_DIR/$SLOT_NAME.started"
while [ ! -e "$SLOT_DIR/$SLOT_NAME.release" ]; do
  sleep 0.05
done
printf 'end %s\n' "$SLOT_NAME" >>"$SLOT_LOG"
exit "$(cat "$SLOT_DIR/$SLOT_NAME.status" 2>/dev/null || printf 0)"
SCRIPT
  cat >"$pass_bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
printf 'run\n' >>"$PASS_LOG"
SCRIPT
  cat >"$mutate_bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
case $MUTATE in
content) printf 'changed\n' >tracked ;;
touch) touch tracked ;;
artifact) printf 'output\n' >artifact ;;
layout) mkdir -p sub/.layout ;;
esac
SCRIPT
  chmod +x "$slot_bin/devenv" "$pass_bin/devenv" "$mutate_bin/devenv"
  sed -i "1c#!$BASH" "$slot_bin/devenv" "$pass_bin/devenv" "$mutate_bin/devenv"
}

# 引数 $1: 場面の名前、$2: その repository の T1 の予算秒
# 制御 directory と、tracked file を持つ T1 の repository を作り、その根へ移る
slot_prepare() {
  slot_repo=$fixture/slot-$1
  slot_dir=$fixture/slot-$1-control
  slot_log=$slot_dir/log
  mkdir -p "$slot_dir"
  : >"$slot_log"
  t1_repository "$slot_repo" "$2"
  printf 'original\n' >"$slot_repo/tracked"
  git -C "$slot_repo" add tracked
  git -C "$slot_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm tracked
  slot_file=$("$GATE" slot --repo "$slot_repo")
  cd "$slot_repo"
}

# 引数 $1: 走行の名前。制御 file の名にも使う。PID は slot_pid へ置く
slot_start() {
  SLOT_NAME=$1 SLOT_DIR=$slot_dir SLOT_LOG=$slot_log PATH="$slot_bin:$PATH" \
    "$VERIFY" -- devenv shell -- verify 2>"$slot_dir/$1.stderr" &
  slot_pid=$!
}

slot_await() {
  local _
  for _ in $(seq 1 400); do
    [ ! -e "$1" ] || return 0
    sleep 0.05
  done
  echo "timed out waiting for $1" >&2
  exit 1
}

slot_await_waiting() {
  local _
  for _ in $(seq 1 400); do
    if [ -s "$slot_dir/$1.stderr" ] && [[ $(<"$slot_dir/$1.stderr") == *実行枠* ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "T1 $1 never reported that it waits for the slot" >&2
  exit 1
}

slot_finish() {
  slot_status=0
  wait "$1" || slot_status=$?
}

slot_expect_free() {
  if ! flock -n "$slot_file" true; then
    echo "the slot is still held after $1" >&2
    exit 1
  fi
}

# agent session が launcher の証明付きで割り当てた scratch を作る。名前は slot_session_tmp へ置く
slot_session() {
  local sessions=$home/.cache/dotfiles-wsl/sessions
  slot_session_id=fixture-slot-$1.omp.4300.AbCd1234
  slot_session_tmp=$sessions/$slot_session_id/tmp
  mkdir -p "$slot_session_tmp"
  session_metadata "$slot_session_id" 1 >"$sessions/$slot_session_id/metadata.json"
}

# 同じ project の T1 は枠の中で一度に一つだけ走り、待った走行も自分の command を実行する
check_slot_exclusive() {
  local first second
  slot_prepare exclusive 60
  slot_start first
  first=$slot_pid
  slot_await "$slot_dir/first.started"
  slot_start second
  second=$slot_pid
  slot_await_waiting second
  sleep 0.3
  if [ -e "$slot_dir/second.started" ]; then
    echo 'a second T1 of the same project ran its command while the first one held the slot' >&2
    exit 1
  fi
  : >"$slot_dir/first.release"
  slot_finish "$first"
  test "$slot_status" -eq 0
  slot_await "$slot_dir/second.started"
  : >"$slot_dir/second.release"
  slot_finish "$second"
  test "$slot_status" -eq 0
  test "$(<"$slot_log")" = $'start first original\nend first\nstart second original\nend second'
  expect_open_gate "$slot_repo" 'serialized runs'
  slot_expect_free 'both T1 runs'
}

# 枠を待つ走行を取消しても、待った走行は command を実行せず何も残さず、枠を持つ走行へ影響しない
check_slot_waiter_cancel() {
  local first second litter
  slot_prepare waiter-cancel 60
  slot_start first
  first=$slot_pid
  slot_await "$slot_dir/first.started"
  litter=$(stall_litter)
  slot_start second
  second=$slot_pid
  slot_await_waiting second
  kill -TERM "$second"
  slot_finish "$second"
  test "$slot_status" -ne 0
  test ! -e "$slot_dir/second.started"
  test "$(stall_litter)" = "$litter"
  : >"$slot_dir/first.release"
  slot_finish "$first"
  test "$slot_status" -eq 0
  test "$(<"$slot_log")" = $'start first original\nend first'
  expect_open_gate "$slot_repo" 'holder after a cancelled waiter'
  slot_expect_free 'a cancelled waiter'
}

# 先行の失敗は、待った走行の結果にも成功の根拠にもならない。待った走行が自分の command を実行する
check_slot_producer_failure() {
  local first second receipts
  slot_prepare producer-failure 60
  receipts=$(stall_receipt_count)
  slot_start first
  first=$slot_pid
  slot_await "$slot_dir/first.started"
  slot_start second
  second=$slot_pid
  slot_await_waiting second
  printf '7\n' >"$slot_dir/first.status"
  : >"$slot_dir/first.release"
  slot_finish "$first"
  test "$slot_status" -eq 7
  slot_await "$slot_dir/second.started"
  expect_closed_gate "$slot_repo" 'failed holder while the waiter runs'
  : >"$slot_dir/second.release"
  slot_finish "$second"
  test "$slot_status" -eq 0
  test "$(<"$slot_log")" = $'start first original\nend first\nstart second original\nend second'
  test "$(stall_receipt_count)" = "$((receipts + 1))"
  expect_open_gate "$slot_repo" 'waiter after a failed holder'
}

# 枠を待つ間に木が変わっても、待った走行は変わった木を実行して証跡もその木へ結ぶ。先行の証跡は借りない
check_slot_source_edit_while_waiting() {
  local first second receipts
  slot_prepare source-edit 60
  receipts=$(stall_receipt_count)
  slot_start first
  first=$slot_pid
  slot_await "$slot_dir/first.started"
  slot_start second
  second=$slot_pid
  slot_await_waiting second
  printf 'edited\n' >"$slot_repo/tracked"
  : >"$slot_dir/first.release"
  slot_finish "$first"
  test "$slot_status" -eq 0
  [[ $(<"$slot_dir/first.stderr") == *木が変わった* ]]
  test "$(stall_receipt_count)" = "$receipts"
  slot_await "$slot_dir/second.started"
  : >"$slot_dir/second.release"
  slot_finish "$second"
  test "$slot_status" -eq 0
  test "$(<"$slot_log")" = $'start first original\nend first\nstart second edited\nend second'
  expect_open_gate "$slot_repo" 'edited tree that the waiter ran'
  git -C "$slot_repo" checkout -q -- tracked
  expect_closed_gate "$slot_repo" 'original tree that no run verified'
}

# 枠の待ちは走行の予算に含まれる。予算を使い切った走行は command を実行せず、何も残さない
check_slot_waiter_deadline() {
  local holder status litter started _
  slot_prepare waiter-deadline 3
  "$BASH" -c 'exec {fd}>>"$1"; flock -x "$fd"; exec sleep 120' _ "$slot_file" &
  holder=$!
  for _ in $(seq 1 400); do
    if ! flock -n "$slot_file" true; then break; fi
    sleep 0.05
  done
  if flock -n "$slot_file" true; then
    echo 'the native holder never took the slot' >&2
    exit 1
  fi
  litter=$(stall_litter)
  started=$SECONDS
  status=0
  SLOT_NAME=waiter SLOT_DIR=$slot_dir SLOT_LOG=$slot_log PATH="$slot_bin:$PATH" \
    "$VERIFY" -- devenv shell -- verify 2>"$slot_dir/waiter.stderr" || status=$?
  test "$status" -eq 124
  test "$((SECONDS - started))" -lt 30
  test ! -e "$slot_dir/waiter.started"
  [[ $(<"$slot_dir/waiter.stderr") == *予算* ]]
  test "$(stall_litter)" = "$litter"
  expect_closed_gate "$slot_repo" 'run that waited out its budget'
  kill "$holder"
  wait "$holder" || true
  : >"$slot_dir/retry.release"
  SLOT_NAME=retry SLOT_DIR=$slot_dir SLOT_LOG=$slot_log PATH="$slot_bin:$PATH" \
    "$VERIFY" -- devenv shell -- verify
  expect_open_gate "$slot_repo" 'run after the holder released the slot'
}

# 走行の取消は、枠と木の外の一時 file と仮の控えを残さない。session の scratch も空に戻る
check_slot_cancel_cleanup() {
  local litter
  local -x DOTFILES_AGENT_SESSION_ID TMPDIR
  slot_prepare cancel-cleanup 60
  slot_session cancel-cleanup
  DOTFILES_AGENT_SESSION_ID=$slot_session_id
  TMPDIR=$slot_session_tmp
  litter=$(stall_litter)
  slot_start running
  slot_await "$slot_dir/running.started"
  kill -TERM "$slot_pid"
  slot_finish "$slot_pid"
  test "$slot_status" -ne 0
  if process_alive "$(<"$slot_dir/running.pid")"; then
    echo 'a cancelled T1 returned while its command was still running' >&2
    exit 1
  fi
  slot_expect_free 'a cancelled T1'
  test "$(stall_litter)" = "$litter"
  test -z "$(find "$slot_session_tmp" -mindepth 1 -print -quit)"
  expect_closed_gate "$slot_repo" 'cancelled run'
}

# 呼び出し元が死んでも、枠は command の子孫が消えるまで残り、残った仮の控えは次の走行が捨てる
check_slot_parent_death() {
  local litter stale _
  slot_prepare parent-death 60
  litter=$(stall_litter)
  slot_start orphaned
  slot_await "$slot_dir/orphaned.started"
  kill -KILL "$slot_pid"
  slot_finish "$slot_pid"
  for _ in $(seq 1 400); do
    process_alive "$(<"$slot_dir/orphaned.pid")" || break
    sleep 0.05
  done
  if process_alive "$(<"$slot_dir/orphaned.pid")"; then
    echo 'the command outlived its killed caller' >&2
    exit 1
  fi
  for _ in $(seq 1 400); do
    ! flock -n "$slot_file" true || break
    sleep 0.05
  done
  slot_expect_free 'the killed caller'
  stale=$(find "$home/.cache/dotfiles-wsl/verification" -name '.pending.*' -print -quit)
  if [ -z "$stale" ]; then
    echo 'the killed caller left no pending receipt, so the next run has nothing to reap' >&2
    exit 1
  fi
  : >"$slot_dir/next.release"
  slot_start next
  slot_finish "$slot_pid"
  test "$slot_status" -eq 0
  test "$(stall_litter)" = "$litter"
  expect_open_gate "$slot_repo" 'run after the killed caller'
}

# 引数 $1: repository、$2: 説明。command は成功し、証跡は作られない
slot_pass_refused() {
  local status=0
  PATH="$pass_bin:$PATH" "$VERIFY" -- devenv shell -- verify 2>"$fixture/refusal.stderr" || status=$?
  test "$status" -eq 0
  [[ $(<"$fixture/refusal.stderr") == *証跡を作らない* ]]
  expect_closed_gate "$1" "$2"
}

# 走行の間に木が触られた、または照合できない木へは証跡を作らない。command の成功は変えない
check_slot_refusals() {
  local repository=$fixture/refusal mutation status receipts
  t1_repository "$repository" 60
  printf 'original\n' >"$repository/tracked"
  git -C "$repository" add tracked
  git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm tracked
  cd "$repository"
  receipts=$(stall_receipt_count)
  for mutation in content touch artifact; do
    status=0
    MUTATE=$mutation PATH="$mutate_bin:$PATH" "$VERIFY" -- devenv shell -- verify \
      2>"$fixture/refusal-$mutation.stderr" || status=$?
    test "$status" -eq 0
    [[ $(<"$fixture/refusal-$mutation.stderr") == *木が変わった* ]]
    expect_closed_gate "$repository" "tree touched by T1 ($mutation)"
    test "$(stall_receipt_count)" = "$receipts"
    git -C "$repository" checkout -q -- tracked
    rm -f "$repository/artifact"
    expect_closed_gate "$repository" "restored tree after T1 ($mutation)"
  done
  MUTATE=none PATH="$mutate_bin:$PATH" "$VERIFY" -- devenv shell -- verify
  expect_open_gate "$repository" 'T1 that left the tree alone'

  # 汚れた gitlink、変更検出を偽る印、.git の無い gitlink は照合できない。gitlink の配置は照合値へ入らない
  repository=$fixture/refusal-gitlink
  t1_repository "$repository" 60
  git -C "$repository" -c protocol.file.allow=always submodule add -q "$submodule_repo" sub
  git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm submodule
  cd "$repository"
  printf 'dirty\n' >"$repository/sub/untracked"
  slot_pass_refused "$repository" 'untracked file in a gitlink'
  rm "$repository/sub/untracked"
  git -C "$repository/sub" update-index --assume-unchanged tracked
  printf 'changed\n' >"$repository/sub/tracked"
  slot_pass_refused "$repository" 'assume-unchanged content in a gitlink'
  git -C "$repository/sub" update-index --no-assume-unchanged tracked
  git -C "$repository/sub" checkout -q -- tracked
  mv "$repository/sub/.git" "$fixture/refusal-sub-dotgit"
  slot_pass_refused "$repository" 'gitlink without its own repository'
  mv "$fixture/refusal-sub-dotgit" "$repository/sub/.git"
  MUTATE=layout PATH="$mutate_bin:$PATH" "$VERIFY" -- devenv shell -- verify
  expect_open_gate "$repository" 'clean gitlink whose directory layout changed during T1'
}

# 一時 file が検査する木の中へ入る TMPDIR は、symlink 越しでも証跡を作らない。空の TMPDIR は未指定と同じである
check_slot_tmpdir() {
  local repository=$fixture/tmpdir status tmpdir
  t1_repository "$repository" 60
  mkdir "$repository/scratch"
  ln -s "$repository/scratch" "$fixture/tmpdir-link"
  cd "$repository"
  for tmpdir in "$repository/scratch" "$fixture/tmpdir-link"; do
    status=0
    TMPDIR=$tmpdir PATH="$pass_bin:$PATH" "$VERIFY" -- devenv shell -- verify \
      2>"$fixture/tmpdir.stderr" || status=$?
    test "$status" -eq 0
    [[ $(<"$fixture/tmpdir.stderr") == *TMPDIR* ]]
    expect_closed_gate "$repository" "TMPDIR $tmpdir inside the tree"
  done
  TMPDIR='' PATH="$pass_bin:$PATH" "$VERIFY" -- devenv shell -- verify
  expect_open_gate "$repository" 'empty TMPDIR'
}

# 検証の状態は自分だけが書ける実 directory に直し、symlink や他人の directory へは控えも枠も置かず command も実行しない
check_slot_state_directories() {
  local repository=$fixture/state-directories state foreign=$fixture/foreign-state status runs
  t1_repository "$repository" 60
  cd "$repository"
  mkdir -p "$home/.cache/dotfiles-wsl/verification"
  chmod 0777 "$home/.cache/dotfiles-wsl" "$home/.cache/dotfiles-wsl/verification"
  PATH="$pass_bin:$PATH" "$VERIFY" -- devenv shell -- verify
  state=$(dirname "$("$GATE" slot --repo "$repository")")
  test "$(stat -c %a "$home/.cache/dotfiles-wsl")" = 700
  test "$(stat -c %a "$home/.cache/dotfiles-wsl/verification")" = 700
  test "$(stat -c %a "$state")" = 700
  test "$(stat -c %a "$state/run.lock")" = 600
  rm -rf "$state"
  mkdir "$foreign"
  ln -s "$foreign" "$state"
  runs=$(wc -l <"$PASS_LOG")
  status=0
  PATH="$pass_bin:$PATH" "$VERIFY" -- devenv shell -- verify 2>"$fixture/state-symlink.stderr" || status=$?
  test "$status" -ne 0
  test "$(wc -l <"$PASS_LOG")" -eq "$runs"
  test -z "$(find "$foreign" -mindepth 1 -print -quit)"
  rm "$state"
}

state_writers=$fixture/state-writers
state_home=$state_writers/home
state_cache=$state_home/.cache/dotfiles-wsl
state_external=$state_writers/external
state_dangling=$state_writers/dangling
state_repository=$state_writers/repository

state_fail() {
  echo "$1" >&2
  exit 1
}

external_state() {
  find "$1" -printf '%P %y %m %s %T@ %l\n' | LC_ALL=C sort
}

reset_state_home() {
  rm -rf "$state_home" "$state_external" "$state_dangling"
  mkdir -p "$state_home/.omp/agent/skills/writer-skill" "$state_external"
  printf '# Writer skill\n' >"$state_home/.omp/agent/skills/writer-skill/SKILL.md"
  printf 'sentinel\n' >"$state_external/sentinel"
  chmod 755 "$state_external"
  chmod 644 "$state_external/sentinel"
}

state_observe() {
  jq -nc --arg session "$state_session" --arg event "$1" --arg cwd "$state_repository" \
    '{session_id:$session,hook_event_name:$event,tool_use_id:"fixture-call",cwd:$cwd,tool_name:"bash",tool_input:{command:"change"}}' |
    "$GATE" hook observe
}

state_stop() {
  jq -nc --arg session "$1" --arg cwd "$state_repository" '{session_id:$session,cwd:$cwd}' |
    "$GATE" hook stop
}

state_writer() {
  case $1 in
  waive) "$GATE" waive --repo "$state_repository" --reason 'fixture reason' ;;
  arm) "$GATE" arm --session "$state_session" --path "$state_repository" ;;
  arm-hook)
    jq -nc --arg session "$state_session" --arg cwd "$state_repository" '{session_id:$session,cwd:$cwd}' |
      "$GATE" hook arm
    ;;
  observe) state_observe PreToolUse ;;
  learned) "$GATE" learned --session "$state_session" --path writer-skill ;;
  learn-hook) skill_read_event "$state_session" PostToolUse read '{"path":"skill://writer-skill"}' ;;
  esac
}

expect_state_writer_refusal() {
  local writer=$1 status=$2 context=$3
  case $writer in
  arm-hook | observe) [ "$status" -eq 0 ] || state_fail "$writer の拒否が hook を失敗させた($status): $context" ;;
  *) [ "$status" -ne 0 ] || state_fail "$writer が拒否すべき状態へ控えた: $context" ;;
  esac
  [ -s "$state_writers/stderr" ] || state_fail "$writer が拒否の理由を出さなかった: $context"
}

expect_state_content() {
  local writer=$1 file=$2 body=$state_home/.omp/agent/skills/writer-skill/SKILL.md
  local -a held
  case $writer in
  waive) grep -qx 'version=1' "$file" && grep -qx 'reason=fixture reason' "$file" ;;
  arm | arm-hook) [ "$(<"$file")" = "$(realpath -e -- "$state_repository")" ] ;;
  observe) [ "$(wc -l <"$file")" -eq 2 ] ;;
  learned | learn-hook)
    mapfile -t held <"$file"
    [ "${#held[@]}" -eq 2 ] && [ "${held[0]}" = "$(sha256sum <"$body" | cut -d ' ' -f 1)" ] && [ "${held[1]}" = "$body" ]
    ;;
  esac || state_fail "$writer の控えの形が変わった: $file"
}

check_gate_state_writers() {
  local -x HOME=$state_home
  local home=$state_home state_session=fixture-writer
  local writer variant index status before state_file session_dir hash name previous_index
  local -a chain files writers=(waive arm arm-hook observe learned learn-hook)

  mkdir -p "$state_writers"
  t1_repository "$state_repository" 60

  for writer in "${writers[@]}"; do
    reset_state_home
    state_writer "$writer" >/dev/null || state_fail "$writer が通常の状態で控えられなかった"
    mapfile -t chain < <(find "$state_cache" -type d | LC_ALL=C sort)
    mapfile -t files < <(find "$state_cache" -type f)
    [ "${#chain[@]}" -ge 3 ] && [ "${#files[@]}" -eq 1 ] || state_fail "$writer の控えの置き場所が想定と違う: ${chain[*]} ${files[*]}"
    expect_state_content "$writer" "${files[0]}"
    chmod 755 "${chain[@]}"
    state_writer "$writer" >/dev/null || state_fail "$writer が旧い mode の状態へ控えられなかった"
    for name in "${chain[@]}"; do
      [ "$(stat -c %a "$name")" = 700 ] || state_fail "$writer が $name を 0700 にしなかった"
    done
    expect_state_content "$writer" "${files[0]}"

    for index in "${!chain[@]}"; do
      for variant in symlink dangling file; do
        reset_state_home
        mkdir -p "$state_home/.cache"
        for ((previous_index = 0; previous_index < index; previous_index++)); do
          mkdir -m 700 "${chain[previous_index]}"
        done
        case $variant in
        symlink)
          mkdir -p "$state_external/${chain[-1]#"${chain[index]}"}"
          find "$state_external" -type d -exec chmod 755 {} +
          ln -s "$state_external" "${chain[index]}"
          ;;
        dangling) ln -s "$state_dangling" "${chain[index]}" ;;
        file) printf 'not a directory\n' >"${chain[index]}" ;;
        esac
        before=$(external_state "$state_external")
        status=0
        state_writer "$writer" >/dev/null 2>"$state_writers/stderr" || status=$?
        expect_state_writer_refusal "$writer" "$status" "$variant ${chain[index]}"
        [ "$(external_state "$state_external")" = "$before" ] || state_fail "$writer が $variant の先を変えた: ${chain[index]}"
        case $variant in
        symlink) [ -L "${chain[index]}" ] || state_fail "$writer が symlink を置き換えた: ${chain[index]}" ;;
        dangling) [ -L "${chain[index]}" ] && [ ! -e "$state_dangling" ] || state_fail "$writer が行き先の無い symlink の先を作った" ;;
        file) [ "$(<"${chain[index]}")" = 'not a directory' ] || state_fail "$writer が directory でない祖先を変えた" ;;
        esac
      done
    done

    for variant in symlink dangling directory; do
      reset_state_home
      state_writer "$writer" >/dev/null
      mapfile -t files < <(find "$state_cache" -type f)
      state_file=${files[0]}
      rm -- "$state_file"
      case $variant in
      symlink)
        printf 'external content\n' >"$state_external/target"
        chmod 640 "$state_external/target"
        ln -s "$state_external/target" "$state_file"
        ;;
      dangling) ln -s "$state_dangling" "$state_file" ;;
      directory) mkdir "$state_file" ;;
      esac
      before=$(external_state "$state_external")
      status=0
      state_writer "$writer" >/dev/null 2>"$state_writers/stderr" || status=$?
      expect_state_writer_refusal "$writer" "$status" "state file $variant"
      [ "$(external_state "$state_external")" = "$before" ] || state_fail "$writer が控えの置き場所の symlink の先を変えた"
      case $variant in
      symlink) [ -L "$state_file" ] || state_fail "$writer が控えの symlink を置き換えた" ;;
      dangling) [ -L "$state_file" ] && [ ! -e "$state_dangling" ] || state_fail "$writer が行き先の無い控えの symlink の先を作った" ;;
      directory) [ -d "$state_file" ] && [ ! -L "$state_file" ] || state_fail "$writer が控えの置き場所の directory を変えた" ;;
      esac
    done
  done

  for state_session in .. . a/b ../escape; do
    for writer in arm arm-hook observe learned learn-hook; do
      reset_state_home
      status=0
      state_writer "$writer" >/dev/null 2>"$state_writers/stderr" || status=$?
      expect_state_writer_refusal "$writer" "$status" "session $state_session"
      [ ! -e "$state_cache" ] || state_fail "$writer が session $state_session で状態を作った"
    done
  done
  state_session='fixture-writer'

  reset_state_home
  state_session=fixture-other state_writer arm >/dev/null
  session_dir=$state_cache/verification/sessions/$state_session
  hash=$(printf '%s' fixture-call | sha256sum | cut -d ' ' -f 1)
  mkdir "$state_external/calls"
  printf 'stale-fingerprint\n%s\n' "$state_repository" >"$state_external/calls/$hash"
  ln -s "$state_external" "$session_dir"
  before=$(external_state "$state_external")
  status=0
  state_observe PostToolUse >/dev/null 2>"$state_writers/stderr" || status=$?
  expect_state_writer_refusal observe "$status" 'post phase through a linked session'
  [ "$(external_state "$state_external")" = "$before" ] || state_fail 'PostToolUse が外の session の記録を読んで消した'

  reset_state_home
  state_observe PreToolUse
  printf 'changed\n' >"$state_repository/state-writers-change"
  state_observe PostToolUse
  rm "$state_repository/state-writers-change"
  session_dir=$state_cache/verification/sessions/$state_session
  [ ! -e "$session_dir/calls/$hash" ] || state_fail 'PostToolUse が前の記録を捨てなかった'
  [ "$(find "$session_dir" -maxdepth 1 -type f | wc -l)" -eq 1 ] || state_fail '木を変えた呼び出しが repository を控えなかった'

  reset_state_home
  state_writer arm >/dev/null
  state_writer observe >/dev/null
  status=0
  state_stop "$state_session" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || state_fail "stop が未検証の木を止めなかった($status)"
  [ ! -e "$session_dir/calls" ] || state_fail 'stop が未対の呼び出しの控えを捨てなかった'
  [ "$(find "$session_dir" -maxdepth 1 -type f | wc -l)" -eq 1 ] || state_fail 'stop が再開のための控えを捨てた'
  state_writer waive >/dev/null
  state_stop "$state_session" >/dev/null 2>&1 || state_fail 'stop が理由を残した木を止めた'

  for variant in symlink dangling directory; do
    reset_state_home
    state_writer arm >/dev/null
    state_writer waive >/dev/null
    mapfile -t files < <(find "$session_dir" -maxdepth 1 -type f)
    state_file=${files[0]}
    mv "$state_file" "$state_external/marker"
    case $variant in
    symlink) ln -s "$state_external/marker" "$state_file" ;;
    dangling) ln -s "$state_dangling" "$state_file" ;;
    directory) mkdir "$state_file" ;;
    esac
    status=0
    state_stop "$state_session" >/dev/null 2>&1 || status=$?
    [ "$status" -eq 2 ] || state_fail "stop が不正な控えを検証済みと扱った: $variant ($status)"
    [ -f "$state_external/marker" ] || state_fail 'stop が外の控えを削除した'
  done

  reset_state_home
  state_observe PreToolUse
  state_file=$session_dir/calls/$hash
  mv "$state_file" "$state_external/call"
  ln -s "$state_external/call" "$state_file"
  state_observe PostToolUse
  [ -L "$state_file" ] && [ -f "$state_external/call" ] || state_fail 'PostToolUse がsymlinkの控えを消費した'

  for variant in file directory; do
    reset_state_home
    state_writer waive >/dev/null
    mapfile -t files < <(find "$state_cache" -name '*.waived' -type f)
    state_file=${files[0]}
    if [ "$variant" = file ]; then
      mv "$state_file" "$state_external/waiver"
      ln -s "$state_external/waiver" "$state_file"
    else
      mv "${state_file%/*}" "$state_external/project"
      ln -s "$state_external/project" "${state_file%/*}"
    fi
    status=0
    "$GATE" check --repo "$state_repository" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ] || state_fail "check がsymlinkの免除を受理した: $variant"
  done

  reset_state_home
  state_writer arm >/dev/null
  rm -rf "$session_dir"
  mkdir "$state_external/calls"
  printf 'stale\n' >"$state_external/calls/leftover"
  printf '%s\n' "$state_repository" >"$state_external/marker"
  ln -s "$state_external" "$session_dir"
  before=$(external_state "$state_external")
  status=0
  state_stop "$state_session" >"$state_writers/stdout" 2>"$state_writers/stderr" || status=$?
  [ "$status" -eq 2 ] && [ -s "$state_writers/stdout" ] && [ -s "$state_writers/stderr" ] \
    || state_fail "stop が実 directory でない session を通した($status)"
  [ "$(external_state "$state_external")" = "$before" ] || state_fail 'stop が外の session の calls を消した'
  rm "$session_dir"
  ln -s "$state_dangling" "$session_dir"
  status=0
  state_stop "$state_session" >"$state_writers/stdout" 2>"$state_writers/stderr" || status=$?
  [ "$status" -eq 2 ] && [ ! -e "$state_dangling" ] || state_fail "stop が行き先の無い session の symlink を通した($status)"
  rm "$session_dir"
  mkdir -p "$state_cache/verification/calls"
  printf 'keep\n' >"$state_cache/verification/calls/keep"
  status=0
  state_stop .. >"$state_writers/stdout" 2>"$state_writers/stderr" || status=$?
  [ "$status" -eq 2 ] && [ -f "$state_cache/verification/calls/keep" ] || state_fail "stop が名の外の directory を辿った($status)"
}

check_verification_slot() {
  local previous=$PWD
  slot_commands
  check_slot_exclusive
  check_slot_waiter_cancel
  check_slot_producer_failure
  check_slot_source_edit_while_waiting
  check_slot_waiter_deadline
  check_slot_cancel_cleanup
  check_slot_parent_death
  check_slot_refusals
  check_slot_tmpdir
  check_slot_state_directories
  cd "$previous"
}

if [ "${1-}" = --budget-boundary-only ]; then
  check_metadata_snapshot_boundary
  exit 0
fi


if [ "${1-}" = --skills-only ]; then
  mkdir -p "$home"
  export HOME=$home
  check_skill_learning
  check_large_read_proof
  exit 0
fi
mkdir -p "$home" "$submodule_repo"
git -C "$submodule_repo" init -q
git -C "$submodule_repo" config user.name fixture
git -C "$submodule_repo" config user.email fixture@example.invalid
printf 'nested\n' >"$submodule_repo/tracked"
git -C "$submodule_repo" add tracked
git -C "$submodule_repo" commit -qm initial

cat > "$fixture/check" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count=0
test ! -e "$COUNT" || count=$(cat "$COUNT")
printf '%s\n' "$((count + 1))" > "$COUNT"
exit "${CHECK_STATUS:-0}"
SCRIPT
chmod +x "$fixture/check"
sed -i "1c#!$BASH" "$fixture/check"

export HOME=$home
mkdir -p "$HOME/.cache/dotfiles-wsl/verification"

# 門は、入口を宣言する repository でだけ「通っていない」と答える。
# 宣言が無ければ何も要求しない。
gate_repo=$fixture/gate-repo
mkdir -p "$gate_repo"
git -C "$gate_repo" init -q
git -C "$gate_repo" config user.name fixture
git -C "$gate_repo" config user.email fixture@example.invalid
printf 'scripts.verify.exec = "true";\n' >"$gate_repo/devenv.nix"
printf 'held\n' >"$gate_repo/tracked"
declare_budget "$gate_repo" 60
git -C "$gate_repo" add devenv.nix tracked verification-budget.json
git -C "$gate_repo" commit -qm initial
test "$("$GATE" entry --repo "$gate_repo")" = 'devenv shell -- verify'
if "$GATE" check --repo "$gate_repo" >/dev/null 2>&1; then
  echo 'gate passed a tree the entrance never ran on' >&2
  exit 1
fi

# 門を開けるのは、宣言した入口を repository の根で通した走行だけである。部分的な検査や
# 下の directory での入口が通っても、この木で入口が通ったことにはならない。
mkdir -p "$fixture/entry-bin" "$gate_repo/nested"
cat >"$fixture/entry-bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
chmod +x "$fixture/entry-bin/devenv"
sed -i "1c#!$BASH" "$fixture/entry-bin/devenv"
cd "$gate_repo"
COUNT=$fixture/gate-focused-count "$VERIFY" -- "$fixture/check" focused
if "$GATE" check --repo "$gate_repo" >/dev/null 2>&1; then
  echo 'gate passed a tree on which only a focused check ran' >&2
  exit 1
fi
(cd "$gate_repo/nested" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
if "$GATE" check --repo "$gate_repo" >/dev/null 2>&1; then
  echo 'gate passed a tree on which the entrance ran below the repository root' >&2
  exit 1
fi
PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify
"$GATE" check --repo "$gate_repo" >/dev/null
printf 'changed\n' >"$gate_repo/tracked"
if "$GATE" check --repo "$gate_repo" >/dev/null 2>&1; then
  echo 'gate passed a tree that changed after the entrance ran' >&2
  exit 1
fi
"$GATE" waive --repo "$gate_repo" --reason 'fixture' >/dev/null
"$GATE" check --repo "$gate_repo" >/dev/null 2>&1

# 入口を宣言しない repository は素通りする。
rm "$gate_repo/devenv.nix"
"$GATE" check --repo "$gate_repo" >/dev/null

# 門が問うのは T1 の verify だけである。push 前や全量の段だけを宣言する repository は止めない。
printf 'scripts.verify-push.exec = "true";\nscripts.verify-full.exec = "true";\n' >"$gate_repo/devenv.nix"
test -z "$("$GATE" entry --repo "$gate_repo")"
"$GATE" check --repo "$gate_repo" >/dev/null

# 未追跡の綴りが増えた木も、通した木とは別物として扱う。
printf 'scripts.verify.exec = "true";\n' >"$gate_repo/devenv.nix"
git -C "$gate_repo" checkout -q -- tracked
PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify
"$GATE" check --repo "$gate_repo" >/dev/null
printf 'new\n' >"$gate_repo/untracked"
if "$GATE" check --repo "$gate_repo" >/dev/null 2>&1; then
  echo 'gate passed a tree that gained an untracked file' >&2
  exit 1
fi

# shell の呼び出しは、作業場所の木を変えた時だけ stop で問う repository に加わる。
# 読むだけの呼び出しは、未検証の木の上でも stop を止めない。
shell_repo=$fixture/shell-repo
mkdir -p "$shell_repo"
git -C "$shell_repo" init -q
git -C "$shell_repo" config user.name fixture
git -C "$shell_repo" config user.email fixture@example.invalid
printf 'scripts.verify.exec = "true";\n' >"$shell_repo/devenv.nix"
printf 'held\n' >"$shell_repo/tracked"
declare_budget "$shell_repo" 60
git -C "$shell_repo" add devenv.nix tracked verification-budget.json
git -C "$shell_repo" commit -qm initial
shell_observe() {
  printf '{"session_id":"fixture-shell","hook_event_name":"%s","tool_use_id":"%s","cwd":"%s","tool_name":"bash","tool_input":%s}' \
    "$1" "$2" "$3" "$4" | "$GATE" hook observe
}
shell_stop() {
  printf '{"session_id":"fixture-shell","cwd":"%s"}' "$shell_repo" |
    "$GATE" hook stop >/dev/null 2>&1
}
shell_observe PreToolUse read "$shell_repo" '{"command":"git status"}'
shell_observe PostToolUse read "$shell_repo" '{"command":"git status"}'
shell_stop
# 作業場所は tool の cwd を先に採り、session の cwd からの相対も解く。失敗した呼び出しでも、
# 変えた木は問う。
shell_observe PreToolUse write "$fixture" '{"command":"change","cwd":"shell-repo"}'
printf 'changed\n' >"$shell_repo/tracked"
shell_observe PostToolUseFailure write "$fixture" '{"command":"change","cwd":"shell-repo"}'
set +e
shell_stop
shell_stop_status=$?
set -e
if [ "$shell_stop_status" -ne 2 ]; then
  echo "stop did not hold a tree a shell call changed: $shell_stop_status" >&2
  exit 1
fi
(cd "$shell_repo" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
shell_stop

native_budget_repo=$fixture/native-missing-budget-repo
git init -q "$native_budget_repo"
printf '{ outputs = { self }: { apps.x86_64-linux.verify = { type = "app"; program = "/bin/false"; }; }; }\n' \
  >"$native_budget_repo/flake.nix"
printf '{"version":1,"frontend":"nix","entries":["verify"]}\n' >"$native_budget_repo/verification-budget.json"
git -C "$native_budget_repo" add flake.nix verification-budget.json
"$GATE" arm --session fixture-native-budget --path "$native_budget_repo/flake.nix"
set +e
printf '{"session_id":"fixture-native-budget","cwd":"%s"}' "$native_budget_repo" |
  "$GATE" hook stop >"$fixture/native-budget-stop.stdout" 2>"$fixture/native-budget-stop.stderr"
native_budget_stop_status=$?
set -e
test "$native_budget_stop_status" -eq 2
rm "$native_budget_repo/verification-budget.json"
expect_closed_gate "$native_budget_repo" 'removed tracked native metadata'

budget_repo=$fixture/budget-repo
t1_repository "$budget_repo" 2
mkdir "$fixture/budget-bin"
cat >"$fixture/budget-bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
if [ -n "${DEADLINE_RUNS-}" ]; then
  printf 'run\n' >>"$DEADLINE_RUNS"
fi
if [ -n "${DEADLINE_REWRITE-}" ]; then
  printf '{"version":1,"verify":{"seconds":60}}\n' >"$DEADLINE_REWRITE"
fi
if [ "${DEADLINE_SLOW-}" = 1 ]; then
  (sleep 3; touch "$DEADLINE_LATE") &
  wait
fi
if [ "${DEADLINE_SLOW-}" = session ]; then
  setsid bash -c 'printf "%s\n" "$$" >"$DEADLINE_PID"; sleep 4; touch "$DEADLINE_LATE"' </dev/null >/dev/null 2>&1 &
  wait
fi
SCRIPT
chmod +x "$fixture/budget-bin/devenv"
sed -i "1c#!$BASH" "$fixture/budget-bin/devenv"
test "$("$GATE" budget --repo "$budget_repo")" = 2
cd "$budget_repo"
set +e
PATH="$fixture/budget-bin:$PATH" DEADLINE_SLOW=1 DEADLINE_LATE=$fixture/deadline-late \
  "$VERIFY" -- devenv shell -- verify
deadline_status=$?
set -e
test "$deadline_status" -eq 124
if "$GATE" check --repo "$budget_repo" >/dev/null 2>&1; then
  echo 'the timed-out T1 left an accepted source receipt' >&2
  exit 1
fi
sleep 4
test ! -e "$fixture/deadline-late"
PATH="$fixture/budget-bin:$PATH" "$VERIFY" -- devenv shell -- verify
"$GATE" check --repo "$budget_repo" >/dev/null

escape_repo=$fixture/session-escape-budget-repo
t1_repository "$escape_repo" 2
cd "$escape_repo"
rm -f "$fixture/escaped.pid" "$fixture/escaped-late"
set +e
PATH="$fixture/budget-bin:$PATH" DEADLINE_SLOW=session DEADLINE_PID=$fixture/escaped.pid \
  DEADLINE_LATE=$fixture/escaped-late "$VERIFY" -- devenv shell -- verify
escape_status=$?
set -e
test "$escape_status" -eq 124
if [ ! -s "$fixture/escaped.pid" ]; then
  echo 'the T1 entry never started the delayed writer in its own session' >&2
  exit 1
fi
if process_alive "$(<"$fixture/escaped.pid")"; then
  echo 'T1 returned at its budget while a descendant in its own session was still running' >&2
  exit 1
fi
if [ -e "$fixture/escaped-late" ]; then
  echo 'a descendant in its own session wrote after T1 returned at its budget' >&2
  exit 1
fi
expect_closed_gate "$escape_repo" 'descendant in its own session'

long_budget_repo=$fixture/long-budget-repo
t1_repository "$long_budget_repo" 10
test "$("$GATE" budget --repo "$long_budget_repo")" = 10
cd "$long_budget_repo"
PATH="$fixture/budget-bin:$PATH" DEADLINE_SLOW=1 DEADLINE_LATE=$fixture/long-deadline-late \
  "$VERIFY" -- devenv shell -- verify
test -e "$fixture/long-deadline-late"
expect_open_gate "$long_budget_repo" 'project that declared a larger budget'

rewrite_repo=$fixture/rewrite-budget-repo
t1_repository "$rewrite_repo" 2
cd "$rewrite_repo"
set +e
PATH="$fixture/budget-bin:$PATH" DEADLINE_SLOW=1 DEADLINE_LATE=$fixture/rewrite-late \
  DEADLINE_REWRITE=$rewrite_repo/verification-budget.json "$VERIFY" -- devenv shell -- verify
rewrite_status=$?
set -e
test "$rewrite_status" -eq 124
expect_closed_gate "$rewrite_repo" 'budget rewritten during the run'
sleep 4
test ! -e "$fixture/rewrite-late"

resolution_repo=$fixture/slow-resolution-repo
t1_repository "$resolution_repo" 2
cd "$resolution_repo"
litter_before=$(stall_litter)
receipts_before=$(stall_receipt_count)
rm -f "$fixture/resolution-runs"
set +e
PATH="$fixture/budget-bin:$PATH" DEADLINE_RUNS=$fixture/resolution-runs \
  "$SLOW_RESOLUTION_VERIFY" -- devenv shell -- verify
resolution_status=$?
set -e
test "$resolution_status" -eq 124
test ! -e "$fixture/resolution-runs"
expect_closed_gate "$resolution_repo" 'resolution that used the whole budget'
test "$(stall_litter)" = "$litter_before"
test "$(stall_receipt_count)" = "$receipts_before"

undeclared_repo=$fixture/undeclared-budget-repo
git init -q "$undeclared_repo"
printf 'scripts.verify.exec = "true";\n' >"$undeclared_repo/devenv.nix"
git -C "$undeclared_repo" add devenv.nix
git -C "$undeclared_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
expect_budget_refused "$undeclared_repo" absent
while read -r name content <&5; do
  printf '%s\n' "$content" >"$undeclared_repo/verification-budget.json"
  expect_budget_refused "$undeclared_repo" "$name"
done 5<<'BUDGETS'
zero {"version":1,"verify":{"seconds":0}}
negative {"version":1,"verify":{"seconds":-5}}
fractional {"version":1,"verify":{"seconds":1.5}}
string {"version":1,"verify":{"seconds":"120"}}
oversized {"version":1,"verify":{"seconds":2147483648}}
version {"version":2,"verify":{"seconds":120}}
stage-missing {"version":1}
seconds-missing {"version":1,"verify":{}}
other-stage {"version":1,"verify-push":{"seconds":120}}
array []
malformed {"version":1,
BUDGETS
cd "$undeclared_repo"
COUNT=$fixture/undeclared-focused-count "$VERIFY" -- "$fixture/check" focused
test "$(cat "$fixture/undeclared-focused-count")" = 1
expect_closed_gate "$undeclared_repo" 'focused check beside an unreadable budget'

# 予算が読めない間は、評価が止まる Nix の宣言も評価しない。
# 入口の綴りと一致する呼び出しだけを実行せず、隣の局所 command は証跡なしで従来どおり走る。
# 評価器が起動すると止まるため、待ち続けず時間を区切って呼ぶ。
stalled_repo=$fixture/stalled-nix-repo
git init -q "$stalled_repo"
cat >"$stalled_repo/flake.nix" <<'NIX'
{
  outputs = { self }: {
    apps =
      let fib = n: if n < 2 then n else fib (n - 1) + fib (n - 2);
      in if fib 60 > 0 then { } else { };
  };
}
NIX
git -C "$stalled_repo" add flake.nix
git -C "$stalled_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
cd "$stalled_repo"
receipts_before=$(stall_receipt_count)
rm -f "$fixture/stalled-focused-count"
started=$SECONDS
COUNT=$fixture/stalled-focused-count NIX_REMOTE="$fixture/nix-store" \
  NIX_CONFIG="experimental-features = nix-command flakes" \
  timeout 60 "$VERIFY" -- "$fixture/check" focused-beside-nix
test "$(cat "$fixture/stalled-focused-count")" = 1
test "$((SECONDS - started))" -lt 30
test "$(stall_receipt_count)" = "$receipts_before"
status=0
NIX_REMOTE="$fixture/nix-store" NIX_CONFIG="experimental-features = nix-command flakes" \
  timeout 60 "$VERIFY" -- nix run --no-write-lock-file .#verify 2>"$fixture/stalled-refused-stderr" || status=$?
if [ "$status" -ne 78 ] || [[ $(<"$fixture/stalled-refused-stderr") != *verification-budget.json* ]]; then
  echo "T1 spelled as the native entry beside an unreadable budget exited $status instead of refusing" >&2
  exit 1
fi
test "$(stall_receipt_count)" = "$receipts_before"
test -z "$(timeout 60 "$GATE" entry --repo "$stalled_repo")"
test "$(timeout 60 "$GATE" candidates --repo "$stalled_repo")" = 'nix run --no-write-lock-file .#verify'
timeout 60 "$GATE" check --repo "$stalled_repo" >/dev/null

printf '{"version":1,"frontend":"nix","entries":["verify"],"verify":{"seconds":2}}\n' >"$stalled_repo/verification-budget.json"
git -C "$stalled_repo" add verification-budget.json
git -C "$stalled_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm budget
litter_before=$(stall_litter)
status=0
# mock の待機は実 Nix の signal 応答を検査できないため不可
real_nix=$(command -v nix)
mkdir "$fixture/nix-observer-bin"
cat >"$fixture/nix-observer-bin/nix" <<'SCRIPT'
#!/usr/bin/env bash
process_stat=$(<"/proc/$$/stat")
read -r -a process_fields <<<"${process_stat##*) }"
printf '%s %s\n' "$$" "${process_fields[19]}" >>"$OBSERVED_NIX_PROCESSES"
exec "$OBSERVED_NIX" "$@"
SCRIPT
chmod +x "$fixture/nix-observer-bin/nix"
sed -i "1c#!$BASH" "$fixture/nix-observer-bin/nix"
rm -f "$fixture/stalled-nix.processes"
# 外側 guard の取消を wrapper の期限と混同するため、終了statusだけの判定は不可
started=$SECONDS
PATH="$fixture/nix-observer-bin:$PATH" OBSERVED_NIX=$real_nix \
  OBSERVED_NIX_PROCESSES=$fixture/stalled-nix.processes \
  NIX_REMOTE="$fixture/nix-store" NIX_CONFIG="experimental-features = nix-command flakes" \
  timeout --preserve-status 60 "$VERIFY" -- nix run --no-write-lock-file .#verify || status=$?
elapsed=$((SECONDS - started))
if [ "$status" -eq 0 ] || [ "$elapsed" -lt 1 ] || [ "$elapsed" -ge 60 ]; then
  echo "T1 over a stalled Nix declaration returned status $status after ${elapsed}s outside its cancellation window" >&2
  exit 1
fi
if [ ! -s "$fixture/stalled-nix.processes" ]; then
  echo 'T1 over a stalled Nix declaration never started the evaluator' >&2
  exit 1
fi
while read -r observed_pid observed_start; do
  if ! process_reaped "$observed_pid" "$observed_start"; then
    echo 'T1 over a stalled Nix declaration returned before its evaluator was reaped' >&2
    exit 1
  fi
done <"$fixture/stalled-nix.processes"
expect_closed_gate_within() {
  local gate_status=0
  started=$SECONDS
  NIX_REMOTE="$fixture/nix-store" NIX_CONFIG="experimental-features = nix-command flakes" \
    timeout 60 "$GATE" check --repo "$1" >/dev/null 2>&1 || gate_status=$?
  if [ "$gate_status" -eq 0 ] || [ "$((SECONDS - started))" -ge 30 ]; then
    echo "gate over a stalled Nix declaration exited $gate_status instead of stopping at its budget" >&2
    exit 1
  fi
}
expect_closed_gate_within "$stalled_repo"
test "$(stall_litter)" = "$litter_before"
test "$(stall_receipt_count)" = "$receipts_before"
rm "$stalled_repo/verification-budget.json"
expect_closed_gate_within "$stalled_repo"
status=0
timeout 60 "$VERIFY" -- nix run --no-write-lock-file .#verify >/dev/null 2>&1 || status=$?
test "$status" -eq 78
test "$(stall_receipt_count)" = "$receipts_before"
cd "$undeclared_repo"

check_metadata_snapshot_boundary

check_receipt_boundaries

check_wrapper_runs_every_time

check_gate_state_writers

check_verification_slot
