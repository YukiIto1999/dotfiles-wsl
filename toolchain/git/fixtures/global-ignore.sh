#!/usr/bin/env bash
set -euo pipefail

# 配備された global ignore の判定を、実際の git に取らせる。
# EDITED_CHECKOUT_* は、checkout が generation の source と違う ignore を持つ構成で作った配備物である。
export HOME=$PWD/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

repo=$PWD/repo
git init -q "$repo"
mkdir -p "$repo/web/node_modules/package"
touch "$repo/web/node_modules/package/index.js" "$repo/$CHECKOUT_ONLY_PATTERN"

# check-ignore は除外で 0、非除外で 1、失敗で 128 を返す。
decision() {
  local excludes=$1 path=$2 status=0
  git -c core.excludesFile="$excludes" -C "$repo" check-ignore -q -- "$path" || status=$?
  case $status in
  0) printf 'ignored\n' ;;
  1) printf 'tracked\n' ;;
  *) fail "git check-ignore failed with status $status for $path using $excludes" ;;
  esac
}

# 対照。checkout の編集が配備物へ入れば除外は確かに変わる。この fixture が差を見分けられる証拠にする。
[ "$(decision "$EDITED_CHECKOUT_IGNORE" "$CHECKOUT_ONLY_PATTERN")" = ignored ] ||
  fail 'the edited checkout ignore did not exclude its own pattern'

for deployed in "$DEPLOYED_IGNORE" "$EDITED_CHECKOUT_DEPLOYED_IGNORE"; do
  resolved=$(readlink -f -- "$deployed")
  case $resolved in
  "$STORE_DIR"/*) ;;
  *) fail "deployed global ignore resolves outside the store: $deployed -> $resolved" ;;
  esac
  [ -f "$resolved" ] || fail "deployed global ignore is not a file: $resolved"
  [ "$(decision "$deployed" web/node_modules/package/index.js)" = ignored ] ||
    fail "deployed global ignore no longer excludes generated dependencies: $deployed"
  [ "$(decision "$deployed" "$CHECKOUT_ONLY_PATTERN")" = tracked ] ||
    fail "an ignore edit that exists only in the checkout reached the deployed global ignore: $deployed"
done

[ "$(readlink -f -- "$DEPLOYED_IGNORE")" = "$(readlink -f -- "$EDITED_CHECKOUT_DEPLOYED_IGNORE")" ] ||
  fail 'the deployed global ignore depends on the checkout location'

printf 'global ignore: store copy; checkout-only edit not applied\n'
