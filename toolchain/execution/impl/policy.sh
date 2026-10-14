set -euo pipefail

usage() {
  printf '%s\n' 'usage: dotfiles-execution-policy [--shared-cache DIR] [--build-root DIR] -- COMMAND [ARG...]' >&2
  exit 2
}

shared_cache=''
build_root=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --shared-cache)
      [ "$#" -ge 2 ] || usage
      shared_cache=$2
      shift 2
      ;;
    --build-root)
      [ "$#" -ge 2 ] || usage
      build_root=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
done
[ "$#" -ge 1 ] || usage

# Cargo の判断に委ねるべき曖昧な設定は上書きしない。
project_has_cargo_output_dir() {
  local directory config_file
  directory=$(pwd -P)

  while :; do
    for config_file in "$directory/.cargo/config.toml" "$directory/.cargo/config"; do
      if [ ! -e "$config_file" ] && [ ! -L "$config_file" ]; then
        continue
      fi

      if [ -L "$config_file" ] || [ ! -f "$config_file" ]; then
        return 0
      fi
      if ! taplo lint --no-auto-config --no-schema "$config_file" >/dev/null 2>&1; then
        return 0
      fi
      if taplo get --file-path "$config_file" build.target-dir >/dev/null 2>&1 \
        || taplo get --file-path "$config_file" build.build-dir >/dev/null 2>&1; then
        return 0
      fi
    done

    [ "$directory" != / ] || break
    directory=${directory%/*}
    test -n "$directory" || directory=/
  done

  return 1
}

# 明示された値は空文字列も含めて呼び出し側のものである。
if [ -n "$shared_cache" ]; then
  if [ "${CARGO_HOME+x}" != x ]; then
    CARGO_HOME="$shared_cache/cargo-home"
    export CARGO_HOME
  fi
  if [ "${XDG_CACHE_HOME+x}" != x ]; then
    XDG_CACHE_HOME="$shared_cache/xdg-cache"
    export XDG_CACHE_HOME
  fi
fi

if [ -n "$build_root" ] \
  && [ "${CARGO_BUILD_BUILD_DIR+x}" != x ] \
  && [ "${CARGO_TARGET_DIR+x}" != x ] \
  && ! project_has_cargo_output_dir; then
  # 同じ workspace の別 checkout の build を Cargo が fresh と判定するため checkout 間で共有する build-dir は不可
  CARGO_BUILD_BUILD_DIR="$build_root/{workspace-path-hash}"
  export CARGO_BUILD_BUILD_DIR
fi

PATH="@shimDirectory@:$PATH"
export PATH
exec "$@"
