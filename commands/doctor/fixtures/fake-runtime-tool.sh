# shellcheck shell=bash

set -euo pipefail

tool=${0##*/}
case "$tool" in
  systemctl)
    [[ ${1-} == show && ${3-} == --property=* && ${4-} == --value ]] || exit 64
    target=$2
    property=${3#--property=}
    [[ $target != *error* ]] || exit 7
    case "$property" in
      LoadState) printf 'loaded\n' ;;
      ActiveState)
        if [[ $target == *fail* ]]; then printf 'inactive\n'; else printf 'active\n'; fi
        ;;
      Result)
        if [[ $target == *result-fail* ]]; then printf 'exit-code\n'; else printf 'success\n'; fi
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
      --format=%F)
        [[ $path != *bad* ]] || { printf 'regular file\n'; exit 0; }
        [[ $path != *error* ]] || exit 7
        printf 'directory\n'
        ;;
      --format=%U:%G:%a)
        [[ $path != *error* ]] || exit 7
        if [[ $path == *bad* ]]; then printf 'nobody:nogroup:777\n'; else printf 'root:root:400\n'; fi
        ;;
      *) exit 64 ;;
    esac
    ;;
  du)
    path=${!#}
    [[ $path != *error* ]] || exit 7
    printf '42\t%s\n' "$path"
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
