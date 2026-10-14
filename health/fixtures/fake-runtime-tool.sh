# shellcheck shell=bash

set -euo pipefail

tool=${0##*/}
case "$tool" in
  systemctl)
    case ${1-} in
      --system) manager=system ;;
      --user) manager=user ;;
      *) exit 64 ;;
    esac
    shift
    [[ ${1-} == show && ${3-} == --property=* ]] || exit 64
    [[ ${4-} == --value || $# == 3 ]] || exit 64
    [[ $manager != user || ${XDG_RUNTIME_DIR-} == /* ]] || exit 1
    target=$2
    properties=${3#--property=}
    [[ $target != *error* ]] || exit 7
    # unit 名の部分文字列で状態を選ぶ擬似の property 値
    #   前提: manager と target と property の設定済みの変数
    #   出力: $target の $property に対する値の一行
    #   終了: manager-down の user manager の 1 と未知の property の 64 による fake 全体の終了
    property_value() {
      case "$manager:$target:$property" in
        user:*manager-down*:*) exit 1 ;;
        user:*status-split-user*:ExecMainStatus | system:*status-split-system*:ExecMainStatus)
          printf '28\n'
          exit 0
          ;;
        user:*result-split-user*:Result)
          printf 'exit-code\n'
          exit 0
          ;;
        user:*only-system*:LoadState | system:*only-user*:LoadState)
          printf 'not-found\n'
          exit 0
          ;;
      esac
      case "$property" in
        LoadState) printf 'loaded\n' ;;
        ActiveState)
          case "$target" in
            *state-starting*) printf 'activating\n' ;;
            *state-draining*) printf 'deactivating\n' ;;
            *state-completed* | *state-failed-cleared* | *state-inconsistent*) printf 'inactive\n' ;;
            *state-failed-state*) printf 'failed\n' ;;
            *state-*) printf 'active\n' ;;
            *fail*) printf 'inactive\n' ;;
            *) printf 'active\n' ;;
          esac
          ;;
        SubState)
          case "$target" in
            *state-starting*) printf 'start\n' ;;
            *state-draining*) printf 'stop-sigterm\n' ;;
            *state-completed* | *state-failed-cleared*) printf 'dead\n' ;;
            *state-failed-state*) printf 'failed\n' ;;
            *state-running* | *state-failed-running* | *state-inconsistent*) printf 'running\n' ;;
            *) printf 'exited\n' ;;
          esac
          ;;
        Result)
          if [[ $target == *result-fail* || $target == *state-failed-running* ]]; then printf 'exit-code\n'; else printf 'success\n'; fi
          ;;
        ExecMainStatus)
          if [[ $target == *exit-fail* || $target == *state-failed-cleared* || $target == *state-failed-running* ]]; then printf '28\n'; else printf '0\n'; fi
          ;;
        UnitFileState)
          if [[ $target == *fail* ]]; then printf 'disabled\n'; else printf 'enabled\n'; fi
          ;;
        NRestarts)
          case "$target" in
            *warn*) printf '5\n' ;;
            *fail*) printf '20\n' ;;
            *) printf '0\n' ;;
          esac
          ;;
        *) exit 64 ;;
      esac
    }
    IFS=, read -r -a property_names <<<"$properties"
    for property in "${property_names[@]}"; do
      value=$(property_value)
      [[ ${4-} == --value ]] || printf '%s=' "$property"
      printf '%s\n' "$value"
    done
    ;;
  docker)
    if [[ ${1-} == image && ${2-} == inspect && ${4-} == --format && ${5-} == '{{.Id}}' ]]; then
      [[ $3 != *error* ]] || exit 7
      printf 'sha256:declared\n'
    elif [[ ${1-} == inspect && ${3-} == --format && ${4-} == '{{.Image}}' ]]; then
      [[ $2 != *error* ]] || exit 7
      if [[ $2 == *mismatch* ]]; then printf 'sha256:running\n'; else printf 'sha256:declared\n'; fi
    elif [[ ${1-} == inspect && ${3-} == --format && ${4-} == '{{.RestartCount}}' ]]; then
      [[ $2 != *error* ]] || exit 7
      case "$2" in
        *warn*) printf '5\n' ;;
        *fail*) printf '20\n' ;;
        *) printf '0\n' ;;
      esac
    else
      exit 64
    fi
    ;;
  stat)
    format=${1-}
    path=${3-}
    [[ ${2-} == -- ]] || exit 64
    case "$format" in
      --format=%U:%G:%a)
        [[ $path != *error* ]] || exit 7
        if [[ $path == *bad* ]]; then printf 'nobody:nogroup:777\n'; else printf 'root:root:400\n'; fi
        ;;
      *) exit 64 ;;
    esac
    ;;
  df)
    path=${!#}
    case "$path" in
      *error*) exit 7 ;;
      *fail*) percent=95 ;;
      *warn*) percent=85 ;;
      *) percent=10 ;;
    esac
    printf 'Use%%\n%s%%\n' "$percent"
    ;;
  zramctl)
    printf '/dev/zram0 lzo-rle\n'
    ;;
  swapon)
    printf '/dev/zram0 partition 4294967296 100\n/dev/sda partition 4294967296 -2\n'
    ;;
  journalctl)
    printf 'Archived and active journals take up 1.0K in the file system.\n'
    ;;
  curl)
    for argument in "$@"; do
      [[ $argument != *health-fail* ]] || exit 22
    done
    ;;
  *)
    exit 64
    ;;
esac
