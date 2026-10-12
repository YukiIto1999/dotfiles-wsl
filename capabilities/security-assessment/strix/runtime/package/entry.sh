#!/usr/bin/env bash

case "${1:-}" in
  -h|--help|-v|--version|view|auth|completion|completions|cloud)
    exec @upstream@ "$@"
    ;;
  --update)
    printf '%s\n' 'strix: this is a pinned Nix deployment; update its declaration and rebuild' >&2
    exit 2
    ;;
esac

original_args=("$@")
args=()
config_source=""
while (( $# )); do
  case "$1" in
    -h|--help|-v|--version)
      exec @upstream@ "${original_args[@]}"
      ;;
    --update)
      printf '%s\n' 'strix: this is a pinned Nix deployment; update its declaration and rebuild' >&2
      exit 2
      ;;
    --config)
      if (( $# < 2 )); then
        printf '%s\n' 'strix: --config requires a JSON file' >&2
        exit 2
      fi
      config_source=$2
      shift 2
      ;;
    --config=*)
      config_source=${1#--config=}
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

runtime_root=${XDG_RUNTIME_DIR:-}
if [[ -z "$runtime_root" || ! -d "$runtime_root" ]] \
  || [[ $(stat -f -c %T "$runtime_root") != tmpfs ]] \
  || [[ $(stat -c %u "$runtime_root") != $(id -u) ]]; then
  printf '%s\n' 'strix: XDG_RUNTIME_DIR must be a user-owned tmpfs directory' >&2
  exit 1
fi

umask 077
runtime_dir=$(mktemp -d "$runtime_root/strix.XXXXXXXX")
child=""
cleanup() {
  trap - EXIT INT TERM
  if [[ -n "$child" ]]; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  rm -rf -- "$runtime_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "$config_source" ]]; then
  cp -- "$config_source" "$runtime_dir/config.json"
else
  printf '%s\n' '{"env":{}}' > "$runtime_dir/config.json"
fi
chmod 0600 "$runtime_dir/config.json"

if [[ ! -r @goApiKeyFile@ ]]; then
  printf '%s\n' 'strix: the managed OpenCode Go credential is unavailable' >&2
  exit 1
fi
IFS= read -r LLM_API_KEY < @goApiKeyFile@ || true
if [[ -z "$LLM_API_KEY" ]]; then
  printf '%s\n' 'strix: the managed OpenCode Go credential is empty' >&2
  exit 1
fi
export LLM_API_KEY
export LLM_API_BASE='https://opencode.ai/zen/go'
export STRIX_LLM='anthropic/minimax-m3'
export LLM_EXTRA_HEADERS='{"User-Agent":"strix/1.7.0 (dotfiles-security-assessment)"}'
export STRIX_RUNTIME_BACKEND=docker
export STRIX_IMAGE='@image@'
export STRIX_TELEMETRY=false
export STRIX_SANDBOX_MEM_LIMIT=2g
export STRIX_SANDBOX_SHM_SIZE=256m
export STRIX_SANDBOX_CPUS=2
export STRIX_SANDBOX_PIDS_LIMIT=256

set +e
@upstream@ --config "$runtime_dir/config.json" "${args[@]}" &
child=$!
wait "$child"
status=$?
child=""
if ! cleanup; then
  printf '%s\n' 'strix: ephemeral credential cleanup is incomplete' >&2
  exit 1
fi
exit "$status"
