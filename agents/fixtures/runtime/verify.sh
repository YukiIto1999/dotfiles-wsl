#!/usr/bin/env bash
set -euo pipefail

fixture=$PWD/verify-fixture
home=$fixture/home
repo=$fixture/repo
gitlink_repo=$fixture/gitlink-repo
nested_gitlink_repo=$fixture/nested-gitlink-repo

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

conformance_stop() {
  jq -nc --arg session "$1" --arg cwd "$home" '{session_id:$session,cwd:$cwd}' |
    "$GATE" hook stop
}

expect_conformance_pending() {
  local output status
  set +e
  output=$(conformance_stop "$1" 2>&1)
  status=$?
  set -e
  if [ "$status" -ne 2 ]; then
    echo "gate let conformance end without current completed coverage: $1 ($status)" >&2
    exit 1
  fi
  case $output in
  *"--session $1"*) ;;
  *) echo "conformance stop omitted the actual session command: $1" >&2; exit 1 ;;
  esac
}

check_conformance_completion() {
  local standard="$fixture/conformance-standard" project="$fixture/conformance-project"
  local report="$fixture/conformance-report.json" body input area output
  local checker="$standard/skills/standard-conformance/scripts/check-coverage.mjs"
  local deployed="$home/.omp/agent/skills"
  mkdir -p "$(dirname "$checker")" "$project/docs" "$deployed"
  cp "$COVERAGE_CHECKER" "$checker"
  cp "$(dirname "$COVERAGE_CHECKER")/../SKILL.md" "$standard/skills/standard-conformance/SKILL.md"
  chmod u+w "$checker" "$standard/skills/standard-conformance/SKILL.md"
  printf '# Standard\n' >"$standard/README.md"
  for area in principles concerns structure tools languages process; do
    mkdir -p "$standard/$area"
    printf '# %s\n' "$area" >"$standard/$area/rule.md"
  done
  git -C "$project" init -q
  git -C "$project" config user.name fixture
  git -C "$project" config user.email fixture@example.invalid
  printf 'source\n' >"$project/tracked"
  printf '{"violations":[]}\n' >"$project/docs/conformance-baseline.json"
  git -C "$project" add tracked docs/conformance-baseline.json
  git -C "$project" commit -qm initial
  ln -s "$standard/skills/standard-conformance" "$deployed/standard-conformance"
  mkdir -p "$deployed/standard-apply"
  printf '# Standard apply\n' >"$deployed/standard-apply/SKILL.md"
  body="$deployed/standard-conformance/SKILL.md"

  input='{"path":"skill://standard-apply"}'
  skill_read_event fixture-apply-only PostToolUse read "$input"
  conformance_stop fixture-apply-only >/dev/null
  input=$(jq -nc --arg path "$body" '{path:$path}')
  skill_read_event fixture-conformance-pre PreToolUse read "$input"
  conformance_stop fixture-conformance-pre >/dev/null
  skill_read_event fixture-conformance-failed PostToolUseFailure read "$input"
  skill_read_event fixture-conformance-truncated PostToolUse read "$input" \
    '{"tool_result":{"details":{"truncation":{"truncated":true}}}}'
  conformance_stop fixture-conformance-truncated >/dev/null
  skill_read_event fixture-conformance-summary PostToolUse read "$input" \
    '{"tool_result":{"details":{"summary":{"lines":1,"elidedSpans":1,"elidedLines":2}}}}'
  conformance_stop fixture-conformance-summary >/dev/null
  skill_read_event fixture-conformance-claude-cap PostToolUse Read "$input" \
    '{"tool_response":{"file":{"truncatedByTokenCap":true}}}'
  conformance_stop fixture-conformance-claude-cap >/dev/null
  conformance_stop fixture-conformance-failed >/dev/null
  input='{"path":"skill://standard-conformance/references/other.md"}'
  skill_read_event fixture-conformance-reference PostToolUse read "$input"
  conformance_stop fixture-conformance-reference >/dev/null
  input=$(jq -nc --arg path "$body" '{path:$path}')
  cat "$body" >/dev/null
  skill_read_event fixture-conformance PostToolUse read "$input"
  expect_conformance_pending fixture-conformance

  node "$checker" inventory --standard-root "$standard" --project-root "$project" |
    jq '{violations:[],baseline:{file:"docs/conformance-baseline.json"},
      coverage:{standardDigest,projectDigest,entries:[.documents[] |
        {document:.,disposition:"checked",evidence:["fixture:source-read"],
         checks:[{kind:"review",status:"passed",evidence:"fixture:completed-review"}]}]}}' >"$report"
  jq '.coverage.entries |= .[1:]' "$report" >"$fixture/conformance-incomplete.json"
  if "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$standard" --report "$fixture/conformance-incomplete.json" >/dev/null 2>&1; then
    echo 'gate recorded an incomplete coverage check as conformance' >&2
    exit 1
  fi
  expect_conformance_pending fixture-conformance
  cp "$report" "$project/internal-report.json"
  if "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$standard" --report "$project/internal-report.json" >/dev/null 2>&1; then
    echo 'gate accepted a report inside the audited Git checkout' >&2
    exit 1
  fi
  rm "$project/internal-report.json"
  expect_conformance_pending fixture-conformance

  "$GATE" learned --session fixture-conformance-admin --path standard-conformance
  if "$GATE" conformance --session fixture-conformance-admin --repo "$project" \
    --standard-root "$standard" --report "$report" >/dev/null 2>&1; then
    echo 'administrative learned created a conformance receipt without a successful read' >&2
    exit 1
  fi
  conformance_stop fixture-conformance-admin >/dev/null

  "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$standard" --report "$report" >/dev/null
  conformance_stop fixture-conformance >/dev/null
  printf '\n' >>"$report"
  expect_conformance_pending fixture-conformance
  "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$standard" --report "$report" >/dev/null
  conformance_stop fixture-conformance >/dev/null

  printf '# Changed standard\n' >"$standard/README.md"
  expect_conformance_pending fixture-conformance
  printf '# Standard\n' >"$standard/README.md"
  conformance_stop fixture-conformance >/dev/null
  printf 'changed\n' >"$project/tracked"
  expect_conformance_pending fixture-conformance
  printf 'source\n' >"$project/tracked"
  conformance_stop fixture-conformance >/dev/null
  cp "$checker" "$fixture/original-checker"
  printf '\n' >>"$checker"
  expect_conformance_pending fixture-conformance
  cp "$fixture/original-checker" "$checker"
  conformance_stop fixture-conformance >/dev/null
  cp "$standard/skills/standard-conformance/SKILL.md" "$fixture/original-conformance-skill"
  printf '\nChanged procedure.\n' >>"$standard/skills/standard-conformance/SKILL.md"
  expect_conformance_pending fixture-conformance
  if "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$standard" --report "$report" >/dev/null 2>&1; then
    echo 'gate accepted changed Skill content without a successful reread' >&2
    exit 1
  fi
  cp "$fixture/original-conformance-skill" "$standard/skills/standard-conformance/SKILL.md"
  "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$standard" --report "$report" >/dev/null
  conformance_stop fixture-conformance >/dev/null

  jq '.baseline.file = "docs/alternate-baseline.json"' "$report" >"$fixture/conformance-alternate.json"
  if "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$standard" --report "$fixture/conformance-alternate.json" >/dev/null 2>&1; then
    echo 'gate accepted a noncanonical baseline authority' >&2
    exit 1
  fi
  expect_conformance_pending fixture-conformance

  cp -r "$standard" "$fixture/other-standard"
  if "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$fixture/other-standard" --report "$report" >/dev/null 2>&1; then
    echo 'gate accepted a copied standard bundle with identical Skill bytes' >&2
    exit 1
  fi
  expect_conformance_pending fixture-conformance
  ln -s "$standard" "$fixture/standard-root-link"
  "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$fixture/standard-root-link" --report "$report" >/dev/null
  conformance_stop fixture-conformance >/dev/null
  ln -sfn "$fixture/other-standard/skills/standard-conformance" "$deployed/standard-conformance"
  expect_conformance_pending fixture-conformance
  if "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$fixture/other-standard" --report "$report" >/dev/null 2>&1; then
    echo 'gate accepted a new physical bundle without a successful canonical reread' >&2
    exit 1
  fi
  ln -sfn "$standard/skills/standard-conformance" "$deployed/standard-conformance"
  "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$standard" --report "$report" >/dev/null
  conformance_stop fixture-conformance >/dev/null
  printf '\nDifferent Skill procedure.\n' >>"$fixture/other-standard/skills/standard-conformance/SKILL.md"
  if "$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$fixture/other-standard" --report "$report" >/dev/null 2>&1; then
    echo 'gate accepted a standard root with a different Skill body' >&2
    exit 1
  fi

  printf '{"violations":[{"rule":"README.md#fixture","file":"tracked","line":1,"evidence":"fixture:existing","mechanizable":false}]}\n' \
    >"$project/docs/conformance-baseline.json"
  node "$checker" inventory --standard-root "$standard" --project-root "$project" |
    jq --slurpfile baseline "$project/docs/conformance-baseline.json" \
      '{violations:$baseline[0].violations,baseline:{file:"docs/conformance-baseline.json"},
        coverage:{standardDigest,projectDigest,entries:[.documents[] |
          {document:.,disposition:"checked",evidence:["fixture:source-read"],
           checks:[{kind:"review",status:"passed",evidence:"fixture:completed-review"}]}]}}' >"$report"
  output=$("$GATE" conformance --session fixture-conformance --repo "$project" \
    --standard-root "$standard" --report "$report")
  printf '%s' "$output" | jq -e '.status == "WARN"' >/dev/null
  conformance_stop fixture-conformance >/dev/null

  rm "$checker"
  output=$(conformance_stop fixture-conformance 2>&1) && {
    echo 'gate accepted old deployed conformance without its checker' >&2
    exit 1
  }
  case $output in
  *source*update*) ;;
  *) echo 'gate omitted the source update reason for a missing checker' >&2; exit 1 ;;
  esac
}

stall_litter() {
  find "$home/.cache/dotfiles-wsl/verification" -mindepth 1 -name '.*' -print | sort
}

stall_receipt_count() {
  find "$home/.cache/dotfiles-wsl/verification" -type f -name '*.verified' -print | wc -l
}

stall_repository() {
  git init -q "$1"
  printf 'scripts.verify.exec = "true";\n' >"$1/devenv.nix"
  git -C "$1" add devenv.nix
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

check_receipt_boundaries() {
  local control=$fixture/stall-control previous=$PWD
  local name utility when pattern initial_runs retry_runs repository litter_before receipts_before status wrapper
  local proof limit foreign process_stat boot_id
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
    stall_repository "$repository"
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
save-before mv before *.success 1 2
save-after mv after *.success 1 1
staged-after mv after */.pending.* 0 1
cleanup-after rm after */.fingerprint.* 1 1
publish-before mv before *.verified 1 1
publish-after mv after *.verified 1 1
SCENARIOS

  while read -r name utility when pattern initial_runs <&4; do
    printf 'receipt cancellation: %s\n' "$name" >&2
    repository=$fixture/stall-$name
    stall_repository "$repository"
    STALL_RUNS=$fixture/stall-$name-runs
    litter_before=$(stall_litter)
    receipts_before=$(stall_receipt_count)
    cd "$repository"
    printf '%s %s %s\n' "$utility" "$when" "$pattern" >"$control"
    rm -f "$control.ready"
    "$CANCELLABLE_VERIFY" -- devenv shell -- verify &
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
    # cache key に SHLVL を含むため同期起動での再試行は不可
    "$CANCELLABLE_VERIFY" -- devenv shell -- verify &
    wait "$!"
    expect_open_gate "$repository" "retry after $name"
    test "$(cat "$STALL_RUNS")" = 1
    test "$(stall_litter)" = "$litter_before"
    test "$(stall_receipt_count)" = "$((receipts_before + 1))"
  done 4<<'SCENARIOS'
cancel-staged mv after */.pending.* 0
cancel-published mv after *.verified 1
SCENARIOS

  for name in late-source capture-source; do
    repository=$fixture/stall-$name
    git init -q "$repository"
    printf '.PHONY: verify\nverify:\n\tprintf old >> ../%s-result\n' "$name" >"$repository/Makefile"
    git -C "$repository" add Makefile
    git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
    litter_before=$(stall_litter)
    cd "$repository"
    if [ "$name" = late-source ]; then pattern='*.success'; else pattern='*/.pending.*'; fi
    printf 'mv after %s\n' "$pattern" >"$control"
    rm -f "$control.ready" "$control.release"
    "$CANCELLABLE_VERIFY" -- make verify &
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
    "$CANCELLABLE_VERIFY" -- make verify
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
    git -C "$repository" add Makefile
    git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
    cd "$repository"
    if [ "$name" = partial-marker ]; then
      printf 'mv after *.verified\n' >"$control"
      rm -f "$control.ready" "$control.release"
    fi
    "$CANCELLABLE_VERIFY" -- make verify &
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
      "$CANCELLABLE_VERIFY" -- make verify &
      wait "$!"
    else
      wait "$wrapper"
    fi
    expect_open_gate "$repository" "$name completed run"
    test "$(cat "$fixture/$name-result")" = once

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
        process_stat=$(<"/proc/$foreign/stat")
        read -r -a process_fields <<<"${process_stat##*) }"
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
  stall_repository "$repository"
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
  test "$(cat "$STALL_RUNS")" = 1
  test "$(stall_receipt_count)" = "$((receipts_before + 1))"
  test "$(stall_litter)" = "$litter_before"

  cd "$previous"
}

if [ "${1-}" = --conformance-only ]; then
  mkdir -p "$home"
  export HOME=$home
  check_conformance_completion
  exit 0
fi

if [ "${1-}" = --skills-only ]; then
  mkdir -p "$home"
  export HOME=$home
  check_skill_learning
  check_large_read_proof
  check_conformance_completion
  exit 0
fi
mkdir -p "$home" "$repo" "$gitlink_repo" "$nested_gitlink_repo"
git -C "$nested_gitlink_repo" init -q
git -C "$nested_gitlink_repo" config user.name fixture
git -C "$nested_gitlink_repo" config user.email fixture@example.invalid
printf 'nested\n' >"$nested_gitlink_repo/tracked"
git -C "$nested_gitlink_repo" add tracked
git -C "$nested_gitlink_repo" commit -qm initial
git -C "$gitlink_repo" init -q
git -C "$gitlink_repo" config user.name fixture
git -C "$gitlink_repo" config user.email fixture@example.invalid
printf 'gitlink\n' >"$gitlink_repo/tracked"
printf 'gitlink missing\n' >"$gitlink_repo/tracked-missing"
printf 'gitlink special\n' >"$gitlink_repo/tracked-special"
printf 'target one\n' >"$gitlink_repo/link-target-one"
printf 'target two\n' >"$gitlink_repo/link-target-two"
ln -s link-target-one "$gitlink_repo/tracked-link"
printf '.layout/\n' >"$gitlink_repo/.gitignore"
git -C "$gitlink_repo" add tracked tracked-missing tracked-special link-target-one \
  link-target-two tracked-link .gitignore
git -C "$gitlink_repo" commit -qm initial
git -C "$gitlink_repo" -c protocol.file.allow=always submodule add -q \
  "$nested_gitlink_repo" nested
git -C "$gitlink_repo" commit -qam nested
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
printf 'tracked\n' > "$repo/tracked"
printf 'tracked missing\n' > "$repo/tracked-missing"
printf 'tracked special\n' > "$repo/tracked-special"
printf 'link target one\n' > "$repo/link-target-one"
printf 'link target two\n' > "$repo/link-target-two"
ln -s link-target-one "$repo/tracked-link"
printf 'ignored\n' > "$repo/.gitignore"
git -C "$repo" add tracked tracked-missing tracked-special link-target-one link-target-two \
  tracked-link .gitignore
git -C "$repo" commit -qm initial

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
export COUNT=$fixture/count
mkdir -p "$HOME/.cache/dotfiles-wsl/verification"
chmod 0777 "$HOME/.cache/dotfiles-wsl" "$HOME/.cache/dotfiles-wsl/verification"
cd "$repo"

cat > "$fixture/environment-check" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count=0
test ! -e "$ENV_COUNT" || count=$(cat "$ENV_COUNT")
printf '%s\n' "$((count + 1))" > "$ENV_COUNT"
test "${DOTFILES_ARBITRARY_INPUT-}" != fail || exit 42
SCRIPT
chmod +x "$fixture/environment-check"
sed -i "1c#!$BASH" "$fixture/environment-check"
export ENV_COUNT=$fixture/environment-count

DOTFILES_ARBITRARY_INPUT=pass "$VERIFY" -- "$fixture/environment-check"
set +e
DOTFILES_ARBITRARY_INPUT=fail "$VERIFY" -- "$fixture/environment-check"
environment_status=$?
set -e
if [ "$environment_status" -ne 42 ]; then
  echo 'verify reused success after arbitrary environment changed' >&2
  exit 1
fi
test "$(cat "$ENV_COUNT")" = 2
project_state=$(find "$HOME/.cache/dotfiles-wsl/verification" -mindepth 1 -maxdepth 1 -type d)
success_file=$(find "$project_state" -type f -name '*.success' -print -quit)
chmod 0666 "$success_file"
DOTFILES_ARBITRARY_INPUT=pass "$VERIFY" -- "$fixture/environment-check"
test "$(cat "$ENV_COUNT")" = 2
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl")" = 700
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl/verification")" = 700
test "$(stat -c %a "$project_state")" = 700
test "$(stat -c %a "$success_file")" = 600

"$VERIFY" -- "$fixture/check" first
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 1

(
  dense_repo=$fixture/dense-repo
  dense_count=$fixture/dense-count
  special_path=$'末尾\n\t\\name'
  mkdir "$dense_repo"
  git -C "$dense_repo" init -q
  git -C "$dense_repo" config user.name fixture
  git -C "$dense_repo" config user.email fixture@example.invalid
  for ((i = 0; i < 513; i++)); do
    printf 'tracked\n' >"$dense_repo/file-$i"
  done
  printf 'special\n' >"$dense_repo/$special_path"
  git -C "$dense_repo" add --all
  git -C "$dense_repo" commit -qm initial
  cd "$dense_repo"
  COUNT=$dense_count "$VERIFY" -- "$fixture/check" dense
  COUNT=$dense_count "$VERIFY" -- "$fixture/check" dense
  test "$(cat "$dense_count")" = 1
  chmod 0444 -- "$special_path"
  COUNT=$dense_count "$VERIFY" -- "$fixture/check" dense
  COUNT=$dense_count "$VERIFY" -- "$fixture/check" dense
  test "$(cat "$dense_count")" = 2
)

original_count=$COUNT
export COUNT=$fixture/mode-count
"$VERIFY" -- "$fixture/check" mode
"$VERIFY" -- "$fixture/check" mode
test "$(cat "$COUNT")" = 1
chmod 0444 tracked
"$VERIFY" -- "$fixture/check" mode
test "$(cat "$COUNT")" = 2
"$VERIFY" -- "$fixture/check" mode
test "$(cat "$COUNT")" = 2
chmod 0644 tracked
export COUNT=$original_count

export COUNT=$fixture/atomic-rewrite-count
"$VERIFY" -- "$fixture/check" atomic-rewrite
"$VERIFY" -- "$fixture/check" atomic-rewrite
if [ "$(cat "$COUNT")" != 1 ]; then
  echo 'verify did not cache the initial atomic-rewrite check' >&2
  exit 1
fi
tracked_inode=$(stat -c %i tracked)
printf 'tracked\n' >"$fixture/tracked-replacement"
chmod 0644 "$fixture/tracked-replacement"
mv -T "$fixture/tracked-replacement" tracked
test "$(stat -c %i tracked)" != "$tracked_inode"
"$VERIFY" -- "$fixture/check" atomic-rewrite
"$VERIFY" -- "$fixture/check" atomic-rewrite
if [ "$(cat "$COUNT")" != 1 ]; then
  echo 'verify invalidated identical content after an inode-only rewrite' >&2
  exit 1
fi

export COUNT=$fixture/symlink-count
"$VERIFY" -- "$fixture/check" symlink
"$VERIFY" -- "$fixture/check" symlink
test "$(cat "$COUNT")" = 1
ln -sfn link-target-two tracked-link
"$VERIFY" -- "$fixture/check" symlink
"$VERIFY" -- "$fixture/check" symlink
test "$(cat "$COUNT")" = 2

export COUNT=$fixture/missing-count
"$VERIFY" -- "$fixture/check" missing
"$VERIFY" -- "$fixture/check" missing
test "$(cat "$COUNT")" = 1
rm tracked-missing
"$VERIFY" -- "$fixture/check" missing
"$VERIFY" -- "$fixture/check" missing
if [ "$(cat "$COUNT")" != 2 ]; then
  echo 'verify did not cache an explicit missing tracked-path state' >&2
  exit 1
fi
printf 'tracked missing\n' > tracked-missing

git -C "$repo" -c protocol.file.allow=always submodule add -q "$gitlink_repo" tracked-gitlink
git -C "$repo" -c protocol.file.allow=always submodule update -q --init --recursive
export COUNT=$fixture/gitlink-clean-count
"$VERIFY" -- "$fixture/check" gitlink
"$VERIFY" -- "$fixture/check" gitlink
if [ "$(cat "$COUNT")" != 1 ]; then
  echo 'verify did not cache a clean gitlink state' >&2
  exit 1
fi

export COUNT=$fixture/gitlink-assume-unchanged-count
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
test "$(cat "$COUNT")" = 1
git -C tracked-gitlink update-index --assume-unchanged tracked
printf 'changed\n' >tracked-gitlink/tracked
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
printf 'mutated\n' >tracked-gitlink/tracked
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
if [ "$(cat "$COUNT")" != 5 ]; then
  echo 'verify reused a cache entry for assume-unchanged gitlink content' >&2
  exit 1
fi
git -C tracked-gitlink update-index --no-assume-unchanged tracked
git -C tracked-gitlink checkout -q -- tracked

export COUNT=$fixture/gitlink-mode-count
git -C tracked-gitlink config core.fileMode false
"$VERIFY" -- "$fixture/check" gitlink-mode
"$VERIFY" -- "$fixture/check" gitlink-mode
test "$(cat "$COUNT")" = 1
chmod 0444 tracked-gitlink/tracked
"$VERIFY" -- "$fixture/check" gitlink-mode
"$VERIFY" -- "$fixture/check" gitlink-mode
if [ "$(cat "$COUNT")" != 2 ]; then
  echo 'verify reused a cache entry for a gitlink mode-only change' >&2
  exit 1
fi
chmod 0644 tracked-gitlink/tracked
git -C tracked-gitlink config core.fileMode true

export COUNT=$fixture/gitlink-symlink-count
"$VERIFY" -- "$fixture/check" gitlink-symlink
"$VERIFY" -- "$fixture/check" gitlink-symlink
test "$(cat "$COUNT")" = 1
git -C tracked-gitlink update-index --assume-unchanged tracked-link
ln -sfn link-target-two tracked-gitlink/tracked-link
"$VERIFY" -- "$fixture/check" gitlink-symlink
"$VERIFY" -- "$fixture/check" gitlink-symlink
if [ "$(cat "$COUNT")" != 3 ]; then
  echo 'verify reused a cache entry for an assume-unchanged gitlink symlink' >&2
  exit 1
fi
git -C tracked-gitlink update-index --no-assume-unchanged tracked-link
git -C tracked-gitlink checkout -q -- tracked-link

export COUNT=$fixture/gitlink-skip-missing-count
"$VERIFY" -- "$fixture/check" gitlink-skip-missing
"$VERIFY" -- "$fixture/check" gitlink-skip-missing
test "$(cat "$COUNT")" = 1
git -C tracked-gitlink update-index --skip-worktree tracked-missing
rm tracked-gitlink/tracked-missing
"$VERIFY" -- "$fixture/check" gitlink-skip-missing
"$VERIFY" -- "$fixture/check" gitlink-skip-missing
if [ "$(cat "$COUNT")" != 3 ]; then
  echo 'verify reused a cache entry for a missing skip-worktree gitlink path' >&2
  exit 1
fi
git -C tracked-gitlink update-index --no-skip-worktree tracked-missing
git -C tracked-gitlink checkout -q -- tracked-missing

export COUNT=$fixture/gitlink-special-count
"$VERIFY" -- "$fixture/check" gitlink-special
"$VERIFY" -- "$fixture/check" gitlink-special
test "$(cat "$COUNT")" = 1
git -C tracked-gitlink update-index --assume-unchanged tracked-special
rm tracked-gitlink/tracked-special
mkdir tracked-gitlink/tracked-special
"$VERIFY" -- "$fixture/check" gitlink-special
"$VERIFY" -- "$fixture/check" gitlink-special
if [ "$(cat "$COUNT")" != 3 ]; then
  echo 'verify cached an unverifiable special gitlink path' >&2
  exit 1
fi
rmdir tracked-gitlink/tracked-special
git -C tracked-gitlink update-index --no-assume-unchanged tracked-special
git -C tracked-gitlink checkout -q -- tracked-special

export COUNT=$fixture/gitlink-stage-conflict-count
"$VERIFY" -- "$fixture/check" gitlink-stage-conflict
"$VERIFY" -- "$fixture/check" gitlink-stage-conflict
test "$(cat "$COUNT")" = 1
gitlink_stage_oid=$(git -C tracked-gitlink rev-parse HEAD:tracked-special)
gitlink_zero_oid=${gitlink_stage_oid//?/0}
test "${#gitlink_zero_oid}" -eq "${#gitlink_stage_oid}"
{
  printf '0 %s\ttracked-special\n' "$gitlink_zero_oid"
  printf '100644 %s 1\ttracked-special\n' "$gitlink_stage_oid"
  printf '100644 %s 2\ttracked-special\n' "$gitlink_stage_oid"
  printf '100644 %s 3\ttracked-special\n' "$gitlink_stage_oid"
} | git -C tracked-gitlink update-index --index-info
"$VERIFY" -- "$fixture/check" gitlink-stage-conflict
"$VERIFY" -- "$fixture/check" gitlink-stage-conflict
if [ "$(cat "$COUNT")" != 3 ]; then
  echo 'verify cached an unmerged gitlink index' >&2
  exit 1
fi
git -C tracked-gitlink reset -q HEAD -- tracked-special

export COUNT=$fixture/gitlink-nested-count
"$VERIFY" -- "$fixture/check" gitlink-nested
"$VERIFY" -- "$fixture/check" gitlink-nested
test "$(cat "$COUNT")" = 1
git -C tracked-gitlink/nested update-index --assume-unchanged tracked
printf 'mutate\n' >tracked-gitlink/nested/tracked
"$VERIFY" -- "$fixture/check" gitlink-nested
"$VERIFY" -- "$fixture/check" gitlink-nested
if [ "$(cat "$COUNT")" != 3 ]; then
  echo 'verify reused a cache entry for nested gitlink content' >&2
  exit 1
fi
git -C tracked-gitlink/nested update-index --no-assume-unchanged tracked
git -C tracked-gitlink/nested checkout -q -- tracked

export COUNT=$fixture/gitlink-tracked-dirty-count
printf 'changed\n' >tracked-gitlink/tracked
"$VERIFY" -- "$fixture/check" gitlink-tracked-dirty
"$VERIFY" -- "$fixture/check" gitlink-tracked-dirty
printf 'mutated\n' >tracked-gitlink/tracked
"$VERIFY" -- "$fixture/check" gitlink-tracked-dirty
"$VERIFY" -- "$fixture/check" gitlink-tracked-dirty
if [ "$(cat "$COUNT")" != 4 ]; then
  echo 'verify reused a cache entry for dirty gitlink content' >&2
  exit 1
fi
git -C tracked-gitlink checkout -q -- tracked

export COUNT=$fixture/gitlink-untracked-dirty-count
printf 'untracked\n' >tracked-gitlink/untracked
"$VERIFY" -- "$fixture/check" gitlink-untracked-dirty
"$VERIFY" -- "$fixture/check" gitlink-untracked-dirty
if [ "$(cat "$COUNT")" != 2 ]; then
  echo 'verify reused a cache entry for an untracked-dirty gitlink' >&2
  exit 1
fi
rm tracked-gitlink/untracked

export COUNT=$fixture/gitlink-unverifiable-count
mv tracked-gitlink/.git "$fixture/tracked-gitlink-dotgit"
"$VERIFY" -- "$fixture/check" gitlink-unverifiable
"$VERIFY" -- "$fixture/check" gitlink-unverifiable
if [ "$(cat "$COUNT")" != 2 ]; then
  echo 'verify reused a cache entry for an unverifiable gitlink' >&2
  exit 1
fi
mv "$fixture/tracked-gitlink-dotgit" tracked-gitlink/.git

export COUNT=$fixture/gitlink-layout-count
"$VERIFY" -- "$fixture/check" gitlink-layout
"$VERIFY" -- "$fixture/check" gitlink-layout
test "$(cat "$COUNT")" = 1
mkdir tracked-gitlink/.layout
"$VERIFY" -- "$fixture/check" gitlink-layout
"$VERIFY" -- "$fixture/check" gitlink-layout
if [ "$(cat "$COUNT")" != 1 ]; then
  echo 'verify fingerprint depended on gitlink directory layout metadata' >&2
  exit 1
fi

export COUNT=$fixture/special-count
"$VERIFY" -- "$fixture/check" special
"$VERIFY" -- "$fixture/check" special
test "$(cat "$COUNT")" = 1
rm tracked-special
mkdir tracked-special
"$VERIFY" -- "$fixture/check" special
"$VERIFY" -- "$fixture/check" special
test "$(cat "$COUNT")" = 3
rm -r tracked-special
printf 'tracked special\n' > tracked-special
export COUNT=$original_count

printf 'dirty\n' >> tracked
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 2

printf 'untracked-1\n' > new-file
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 3
printf 'untracked-2\n' > new-file
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 4

printf 'ignored-change\n' > ignored
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 4

RUSTFLAGS=-Cdebuginfo=0 "$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 5
"$VERIFY" -- "$fixture/check" second
test "$(cat "$COUNT")" = 6

set +e
CHECK_STATUS=7 "$VERIFY" -- "$fixture/check" failure
first_failure=$?
CHECK_STATUS=7 "$VERIFY" -- "$fixture/check" failure
second_failure=$?
set -e
test "$first_failure" -eq 7
test "$second_failure" -eq 7
test "$(cat "$COUNT")" = 8

printf 'new head\n' > committed
git add committed
git commit -qm second
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 9

cat > "$fixture/mutating-check" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count=0
test ! -e "$MUTATE_COUNT" || count=$(cat "$MUTATE_COUNT")
printf '%s\n' "$((count + 1))" > "$MUTATE_COUNT"
printf 'stable result\n' > tracked
SCRIPT
chmod +x "$fixture/mutating-check"
sed -i "1c#!$BASH" "$fixture/mutating-check"
export MUTATE_COUNT=$fixture/mutate-count
"$VERIFY" -- "$fixture/mutating-check"
"$VERIFY" -- "$fixture/mutating-check"
"$VERIFY" -- "$fixture/mutating-check"
test "$(cat "$MUTATE_COUNT")" = 2

test -n "$(find "$home/.cache/dotfiles-wsl/verification" -type f -name '*.success' -print -quit)"
test -z "$(find "$home/.cache/dotfiles-wsl/verification" -type f \
  ! -name '*.success' ! -name '*.verified' ! -name '*.waived' -print -quit)"

# 門は、入口を宣言する repository でだけ「通っていない」と答える。
# 宣言が無ければ何も要求しない。
gate_repo=$fixture/gate-repo
mkdir -p "$gate_repo"
git -C "$gate_repo" init -q
git -C "$gate_repo" config user.name fixture
git -C "$gate_repo" config user.email fixture@example.invalid
printf 'scripts.verify.exec = "true";\n' >"$gate_repo/devenv.nix"
printf 'held\n' >"$gate_repo/tracked"
git -C "$gate_repo" add devenv.nix tracked
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
git -C "$shell_repo" add devenv.nix tracked
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

broken_repo=$fixture/broken-nix-repo
git init -q "$broken_repo"
printf '{ outputs =\n' >"$broken_repo/flake.nix"
git -C "$broken_repo" add flake.nix
"$GATE" arm --session fixture-broken-nix --path "$broken_repo/flake.nix"
set +e
printf '{"session_id":"fixture-broken-nix","cwd":"%s"}' "$broken_repo" |
  NIX_REMOTE="$fixture/nix-store" NIX_CONFIG="experimental-features = nix-command flakes" \
    "$GATE" hook stop >"$fixture/broken-stop.stdout" 2>"$fixture/broken-stop.stderr"
broken_stop_status=$?
set -e
test "$broken_stop_status" -eq 2
test -s "$fixture/broken-stop.stderr"

budget_repo=$fixture/budget-repo
git init -q "$budget_repo"
printf 'scripts.verify.exec = "true";\n' >"$budget_repo/devenv.nix"
git -C "$budget_repo" add devenv.nix
git -C "$budget_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
mkdir "$fixture/budget-bin"
cat >"$fixture/budget-bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
if [ "${DEADLINE_SLOW-}" = 1 ]; then
  (sleep 3; touch "$DEADLINE_LATE") &
  wait
fi
SCRIPT
chmod +x "$fixture/budget-bin/devenv"
sed -i "1c#!$BASH" "$fixture/budget-bin/devenv"
cd "$budget_repo"
set +e
PATH="$fixture/budget-bin:$PATH" DEADLINE_SLOW=1 DEADLINE_LATE=$fixture/deadline-late \
  "$SHORT_BUDGET_VERIFY" -- devenv shell -- verify
deadline_status=$?
set -e
test "$deadline_status" -eq 124
if "$GATE" check --repo "$budget_repo" >/dev/null 2>&1; then
  echo 'the timed-out T1 left an accepted source receipt' >&2
  exit 1
fi
sleep 4
test ! -e "$fixture/deadline-late"
PATH="$fixture/budget-bin:$PATH" "$SHORT_BUDGET_VERIFY" -- devenv shell -- verify
"$GATE" check --repo "$budget_repo" >/dev/null
check_receipt_boundaries

check_skill_learning
check_conformance_completion

outside=$fixture/outside
mkdir "$outside"
cd "$outside"
"$VERIFY" -- "$fixture/check" outside
"$VERIFY" -- "$fixture/check" outside
test "$(cat "$COUNT")" = 11
