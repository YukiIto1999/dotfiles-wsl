# shellcheck shell=bash

set -euo pipefail

if [[ $# != 2 || $2 != --open ]]; then
  printf '%s\n' 'Usage: bash smoke-windows.sh /absolute/path/to/wslview --open' \
    'Explicitly open one harmless URL, one local directory and one local HTML file.' \
    'No clipboard, Windows configuration, WSL restart or VHD operation is performed.' >&2
  exit 2
fi
launcher=$1
if [[ ! -x $launcher ]]; then
  printf '%s\n' 'smoke-windows: launcher is not executable' >&2
  exit 1
fi

fixture=$(mktemp -d --tmpdir 'dotfiles-wslview.XXXXXXXX')
trap 'rm -rf -- "$fixture"' EXIT
directory="$fixture/日本語 & 'quoted' [name];\$"
mkdir -- "$directory"
document="$directory/Windows interop smoke.html"
printf '%s\n' '<!doctype html><meta charset="utf-8"><title>dotfiles wslview smoke</title><p>日本語 &amp; spaces: local file opened without shell evaluation.</p>' > "$document"

"$launcher" --help
if "$launcher" > "$fixture/no-argument.stdout" 2> "$fixture/no-argument.stderr"; then
  printf '%s\n' 'smoke-windows: missing target unexpectedly succeeded' >&2
  exit 1
else
  status=$?
  [[ $status == 2 ]]
fi
if "$launcher" https://example.com/ extra > "$fixture/extra-argument.stdout" 2> "$fixture/extra-argument.stderr"; then
  printf '%s\n' 'smoke-windows: application argument unexpectedly accepted' >&2
  exit 1
else
  status=$?
  [[ $status == 2 ]]
fi

"$launcher" 'https://example.com/?dotfiles=1&quoted=%27value%27#interop'
"$launcher" "$directory"
"$launcher" "$document"
"$launcher" "$(wslpath -w "$directory")"
printf '%s\n' \
  'Confirm the example.com tab, the named Explorer directory and the local HTML text.' \
  'A zero launcher status only means Windows accepted the open request.' \
  'Press Enter after recording the visible results; the local fixture is then removed.'
read -r _
