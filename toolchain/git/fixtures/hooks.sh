#!/usr/bin/env bash
set -euo pipefail

# 配備する hook 一式を global の hooksPath に置き、実際の git から起こす。
export HOME=$PWD/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$PWD/home/.gitconfig
mkdir -p "$HOME"
git config --global core.hooksPath "$HOOKS"
git config --global core.excludesFile "$GLOBAL_IGNORE"
git config --global user.name fixture
git config --global user.email fixture@example.invalid
git config --global init.defaultBranch main

remote=$PWD/remote.git
repo=$PWD/repo
marker=$PWD/marker
git init -q --bare "$remote"
git init -q "$repo"
git -C "$repo" remote add origin "$remote"
git -C "$repo" config dotfiles.hooks.trusted true
mkdir "$repo/.githooks"

# repository の hook。名前、argv、stdin を marker へ控え、REPO_HOOK_STATUS で終わる。
write_repo_hook() {
  local name=$1
  cat >"$repo/.githooks/$name" <<SCRIPT
#!$BASH
{
  printf 'hook=%s\n' '$name'
  printf 'arg=%s\n' "\$@"
  printf 'stdin\n'
  cat
} >>"$marker"
exit "\${REPO_HOOK_STATUS:-0}"
SCRIPT
  chmod +x "$repo/.githooks/$name"
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

ignored_paths=(
  nested/__pycache__/entry nested/module.pyc nested/module.pyo
  dotnet/obj/Debug/project.assets.json dotnet/bin/Debug/net10.0/app.dll
  dotnet/Bin/Release/net10.0/app.dll dotnet/.vs/cache
  dotnet/TestResults/run.trx dotnet/BenchmarkDotNet.Artifacts/results/summary
  dotnet/app.csproj.user dotnet/solution.sln.DotSettings.user
  crates/demo/target/debug/demo crates/demo/source.rs.bk crates/demo/rustc-ice-123.txt
  web/node_modules/package/index.js web/app.tsbuildinfo
  web/.next/cache/data web/.svelte-kit/generated/server.js web/.vite/deps/data
  web/.yarn/install-state.gz web/.parcel-cache/data web/.nyc_output/results.json
  web/.pnpm-store/package web/npm-debug.log.1
  python/.venv/pyvenv.cfg python/.pytest_cache/data python/.mypy_cache/data
  python/.ruff_cache/data python/.tox/py/bin/python python/.nox/session/data
  python/demo.egg-info/PKG-INFO python/.ipynb_checkpoints/notebook.ipynb
  python/.pixi/envs/default/bin/python
  jvm/.gradle/cache jvm/App.class jvm/hs_err_pid123.txt
  native/CMakeFiles/cache native/CMakeCache.txt native/cmake-build-debug/cache
  go/run.coverprofile swift/.build/debug/app swift/xcuserdata/user/settings
  dart/.dart_tool/package_config.json dart/.flutter-plugins-dependencies
  ruby/.yardoc/cache ruby/.byebug_history haskell/.stack-work/cache
  elixir/.elixir_ls/cache elixir/_build/dev/lib/app/ebin/app.beam
  r/.Rproj.user/settings terraform/.terraform/providers/cache terraform/local.tfstate
  os/._resource os/.Trash-1000/cache os/ehthumbs_vista.db
)
trackable_paths=(
  dotnet/app.cs dotnet/app.csproj dotnet/Directory.Build.props dotnet/packages.lock.json
  crates/demo/src/main.rs crates/demo/Cargo.toml crates/demo/Cargo.lock
  crates/demo/.cargo/config.toml web/src/app.ts web/src/app.js web/package.json
  web/package-lock.json web/pnpm-lock.yaml web/yarn.lock web/bun.lock web/bun.lockb
  web/tsconfig.json web/.yarn/patches/fix.patch web/.yarn/releases/yarn.cjs
  web/.yarn/plugins/plugin.cjs python/uv.lock python/poetry.lock python/pyproject.toml
  python/.pixi/config.toml jvm/gradle/wrapper/gradle-wrapper.jar native/Makefile
  native/CMakeLists.txt native/CMakePresets.json assets/model.obj assets/sdk.dll
  assets/library.so assets/archive.zip bin/tool build/tasks.sh dist/library.js
  vendor/library/source.php go/go.mod go/go.sum go/go.work swift/Package.resolved
  dart/pubspec.lock ruby/Gemfile.lock haskell/cabal.project.freeze r/data/study.RData
  terraform/main.tf terraform/.terraform.lock.hcl terraform/example.tfvars .env.example
)
for name in "${ignored_paths[@]}" "${trackable_paths[@]}"; do
  mkdir -p "$repo/$(dirname "$name")"
  touch "$repo/$name"
done
for name in "${ignored_paths[@]}"; do
  git -C "$repo" check-ignore -q -- "$name" || fail "global ignore accepted a generated file: $name"
done
for name in "${trackable_paths[@]}"; do
  if git -C "$repo" check-ignore -q -- "$name"; then
    fail "global ignore hid a source, shared setting or lockfile: $name"
  fi
done
git -C "$repo" add --all
for name in "${trackable_paths[@]}"; do
  git -C "$repo" ls-files --error-unmatch -- "$name" >/dev/null || fail "git add missed: $name"
done
for name in "${ignored_paths[@]}"; do
  if git -C "$repo" ls-files --error-unmatch -- "$name" >/dev/null 2>&1; then
    fail "git add staged a generated file: $name"
  fi
done
printf '!web/.next/\n!web/.next/**\n' >"$repo/.gitignore"
git -C "$repo" add .gitignore web/.next/cache/data
git -C "$repo" ls-files --error-unmatch -- web/.next/cache/data >/dev/null \
  || fail 'repository exception did not override the global ignore'
printf 'global ignore: %s generated paths excluded; %s source/configuration paths staged; repository exception accepted\n' \
  "${#ignored_paths[@]}" "${#trackable_paths[@]}"

commit() {
  printf '%s\n' "$1" >>"$repo/tracked"
  git -C "$repo" add tracked
  git -C "$repo" commit -q -m 'test: 検査の追加' </dev/null
}

expect_secret_rejected() {
  local name=$1 expected_secret=$2
  rm -f "$marker"
  git -C "$repo" add -- "$name"
  if git -C "$repo" commit -q -m 'test: 検査の追加' >commit-output 2>&1; then
    fail "pre-commit accepted a staged secret in: $name"
  fi
  test ! -e "$marker" || fail 'repository pre-commit ran after the global check failed'
  grep -qF -- "$name" commit-output || fail 'secret rejection did not name the file'
  if grep -qF -- "$expected_secret" commit-output; then
    fail 'secret rejection exposed the secret in commit output'
  fi
  git -C "$repo" rm -q --cached -- "$name"
  rm -- "$repo/$name"
}

# 信頼した repository では、dotfiles の検査の後に repository の hook が同じ argv で走る。
write_repo_hook pre-commit
write_repo_hook commit-msg
commit first
grep -qx 'hook=pre-commit' "$marker" || fail 'repository pre-commit did not run'
grep -qx 'hook=commit-msg' "$marker" || fail 'repository commit-msg did not run'
grep -qx 'arg=.git/COMMIT_EDITMSG' "$marker" || fail 'repository commit-msg lost its argv'

# dotfiles の検査が拒んだ commit では、repository の hook を走らせない。
rm -f "$marker"
if git -C "$repo" commit -q --allow-empty -m 'fix: update README' 2>/dev/null; then
  fail 'commit-msg accepted an invalid subject'
fi
grep -qx 'hook=commit-msg' "$marker" && fail 'repository commit-msg ran after the global check failed'
for prefix in ghp_ gho_ ghu_ ghs_ ghr_ github_pat_ apikey_ sk-proj- sk-ant- sk-or-v1-; do
  token="$prefix$(printf 'a%.0s' {1..36})"
  printf '%s\n' "$token" >"$repo/leak.txt"
  expect_secret_rejected leak.txt "$token"
  commit "recovered-$prefix"
done

{
  printf '%s\n' "$token"
  printf 'ordinary added source line %.0s\n' {1..4096}
} >"$repo/large-diff.txt"
expect_secret_rejected large-diff.txt "$token"
commit recovered-large-diff

age_key=$PWD/generated-age-key
age-keygen -o "$age_key" 2>/dev/null
age_secret=$(grep -E '^AGE-SECRET-KEY-' "$age_key")
cp "$age_key" "$repo/日本語の notes.txt"
expect_secret_rejected '日本語の notes.txt' "$age_secret"
recipient=$(age-keygen -y "$age_key")
printf 'creation_rules:\n  - age: %s\n' "$recipient" >"$repo/.sops.yaml"
printf 'prefixes = ("apikey_", "sk-proj-", "sk-ant-", "sk-or-v1-", "AGE-SECRET-KEY-")\n' \
  >"$repo/source.py"
git -C "$repo" add .sops.yaml source.py
printf 'unstaged_secret = "%s"\n' "$age_secret" >>"$repo/source.py"
rm -f "$marker"
git -C "$repo" commit -q -m 'test: 検査の追加'
grep -qx 'hook=pre-commit' "$marker" || fail 'repository pre-commit did not run after secret removal'
git -C "$repo" restore -- source.py
rm -- "$age_key"

# repository の hook の失敗は、その終了 status のまま git へ返る。
rm -f "$marker"
set +e
(cd "$repo" && REPO_HOOK_STATUS=3 "$HOOKS/pre-commit")
status=$?
set -e
test "$status" -eq 3 || fail "repository hook status was not propagated: $status"
printf 'second\n' >>"$repo/tracked"
git -C "$repo" add tracked
if REPO_HOOK_STATUS=3 git -C "$repo" commit -q -m 'test: 検査の追加' 2>/dev/null; then
  fail 'git committed although the repository pre-commit failed'
fi
git -C "$repo" commit -q -m 'test: 検査の追加'

# pre-push の ref の一覧は、repository の hook へも同じ stdin で届く。
rm -f "$marker"
write_repo_hook pre-push
head=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q origin main 2>/dev/null
expected_stdin="refs/heads/main $head refs/heads/main $(printf '0%.0s' $(seq 1 ${#head}))"
grep -qx 'hook=pre-push' "$marker" || fail 'repository pre-push did not run'
grep -qx "arg=$remote" "$marker" || fail 'repository pre-push lost the remote URL'
grep -qxF "$expected_stdin" "$marker" || fail 'repository pre-push did not receive the ref list'

# dotfiles が検査を持たない hook でも、repository の hook は走る。
rm -f "$marker"
write_repo_hook post-checkout
git -C "$repo" checkout -q -b topic
grep -qx 'hook=post-checkout' "$marker" || fail 'repository post-checkout did not run'

# 実行権の無い hook は走らせず、何も言わない。
rm -f "$marker"
chmod -x "$repo/.githooks/post-checkout"
git -C "$repo" checkout -q main 2>stderr
test ! -e "$marker" || fail 'a non-executable repository hook ran'
test ! -s stderr || fail 'a non-executable repository hook produced output'
chmod +x "$repo/.githooks/post-checkout"

# 信頼していない repository の hook は走らせず、そのことを一行だけ伝える。
rm -f "$marker"
git -C "$repo" config --unset dotfiles.hooks.trusted
git -C "$repo" checkout -q topic 2>stderr
test ! -e "$marker" || fail 'an untrusted repository hook ran'
test "$(wc -l <stderr)" -eq 1 || fail 'the untrusted notice was not exactly one line'
grep -qF "$repo/.githooks/post-checkout" stderr || fail 'the untrusted notice did not name the hook'
