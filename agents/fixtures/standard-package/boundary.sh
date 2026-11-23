# 検査で resolver の外部作用だけを置き換える。呼ばれた名前で、公開 ref の問い合わせ、archive の取得と
# 隔離 build と out-link、GC root の昇格を、作業 directory の control にある file に従って再現する。検査器は本物を使う。
# 問い合わせは環境を空にして起動されるため、制御 file は継承した作業 directory から読む
set -euo pipefail

control="$(pwd -P)/control"

case "${0##*/}" in
  git)
    printf '%s\n' "$*" >>"$control/lookups.log"
    if [ -n "${STANDARD_PACKAGE_SCENARIO-}" ] || [ "$HOME" != /var/empty ] || [[ $PATH != *:/var/empty ]] \
      || [ "${GIT_CONFIG_GLOBAL-}" != /dev/null ] || [ "${GIT_CONFIG_NOSYSTEM-}" != 1 ] \
      || [ "${GIT_ALLOW_PROTOCOL-}" != https ] || [ ! -f "${GIT_SSL_CAINFO-}" ]; then
      echo 'error: the query did not run in the anonymous environment' >&2
      exit 1
    fi
    if [ "$*" != "-C / ls-remote --exit-code -- https://github.com/standard-owner/standard.git HEAD" ]; then
      echo "error: unexpected query: $*" >&2
      exit 1
    fi
    if [ -e "$control/outage" ]; then
      echo 'fatal: unable to access the remote' >&2
      exit 128
    fi
    printf '%s\tHEAD\n' "$(<"$control/published")"
    # ls-remote の pattern は ref の末尾にも一致する。
    printf '%s\trefs/tags/archive/HEAD\n' "$(<"$control/published")"
    if [ -e "$control/extra-ref" ]; then
      printf '%s\tHEAD\n' "$(<"$control/published")"
    fi
    ;;
  nix-build)
    link='' validator='' archive='' revision=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --out-link) link=$2 && shift 2 ;;
        --option) shift 3 ;;
        --argstr)
          case "$2" in
            validator) validator=$3 ;;
            archive) archive=$3 ;;
            revision) revision=$3 ;;
          esac
          shift 3
          ;;
        *) shift ;;
      esac
    done
    if [ "$archive" != "https://github.com/standard-owner/standard/archive/$revision.tar.gz" ]; then
      echo "error: the archive does not name revision $revision: $archive" >&2
      exit 1
    fi
    if [ -e "$control/hold-$revision" ]; then
      touch "$control/building-$revision"
      while [ ! -e "$control/release-$revision" ]; do
        sleep 0.05
      done
    fi
    if [ ! -f "$control/sources/$revision" ]; then
      echo "error: unable to download the archive of $revision" >&2
      exit 1
    fi
    # store の出力と同じく、成功した build だけが出力を作り out-link を置き換える
    output="$control/store/validation-$revision"
    rm -rf "$output.tmp"
    mkdir -p "$control/store"
    out="$output.tmp" "$validator/bin/dotfiles-standard-package-validate" "$(<"$control/sources/$revision")" "$revision"
    rm -rf "$output"
    mv "$output.tmp" "$output"
    ln -sfn "$output" "$link"
    if [ -e "$control/registration-failure" ]; then
      echo "error: cannot register the indirect root $link" >&2
      exit 1
    fi
    printf '%s\n' "$output"
    ;;
  *)
    echo "unknown boundary: $0" >&2
    exit 64
    ;;
esac
