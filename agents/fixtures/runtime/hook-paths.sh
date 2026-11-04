#!/usr/bin/env bash
set -euo pipefail

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export HOME=$fixture/home
repository=$fixture/repository
mkdir -p "$HOME" "$repository"
git -C "$repository" init -q
git -C "$repository" config user.name fixture
git -C "$repository" config user.email fixture@example.invalid
printf 'scripts.verify.exec = "true";\n' >"$repository/devenv.nix"
printf '{"version":1,"verify":{"seconds":60}}\n' >"$repository/verification-budget.json"
printf 'held\n' >"$repository/tracked"
git -C "$repository" add .
git -C "$repository" commit -qm initial

hook() {
  jq -nc --arg session "$1" --arg cwd "$repository" --arg path "$3" \
    '{session_id:$session,cwd:$cwd,tool_name:"write",tool_input:{path:$path}}' |
    "$GATE" hook "$2"
}

for scheme in xd agent proc local cfg ssh; do
  hook "uri-$scheme" arm "$scheme://outside"
  if ! hook "uri-$scheme" stop '' >/dev/null 2>&1; then
    printf 'non-filesystem write incorrectly required repository verification: %s\n' "$scheme" >&2
    exit 1
  fi
done

printf 'edited\n' >"$repository/tracked"
for path in tracked "$repository/tracked"; do
  session="file-$(printf '%s' "$path" | sha256sum | cut -d ' ' -f 1)"
  hook "$session" arm "$path"
  status=0
  hook "$session" stop '' >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 2 ]; then
    printf 'local edit did not require repository verification: %s (%s)\n' "$path" "$status" >&2
    exit 1
  fi
done
printf 'hook paths: non-filesystem calls pass; local edits still require verification\n'
