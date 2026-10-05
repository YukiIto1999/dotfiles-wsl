# shellcheck shell=bash

if [[ $# == 1 && $1 == --help ]]; then
  printf '%s\n' 'Usage: wslview [--] URL_OR_PATH' \
    'Open one URL, Windows absolute path, or existing Linux file/directory.' \
    'Linux paths are converted with wslpath. Application arguments are not accepted.' \
    'Exit: 0 launch accepted; 2 invalid arguments; 1 local path/conversion failure.' \
    'Windows launcher failures preserve the PowerShell exit status.'
  exit 0
fi
if [[ ${1-} == -- ]]; then
  shift
elif [[ ${1-} == -* ]]; then
  printf '%s\n' 'wslview: unknown option; use -- before a path beginning with -' >&2
  exit 2
fi
if [[ $# != 1 || -z $1 || $1 == *$'\n'* || $1 == *$'\r'* ]]; then
  printf '%s\n' 'Usage: wslview [--] URL_OR_PATH' >&2
  exit 2
fi

target=$1
if [[ $target =~ ^[A-Za-z]:[\\/] || $target == \\\\* ]]; then
  :
elif [[ $target =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]]; then
  :
else
  if ! absolute=$(@realpathCommand@ -e -- "$target"); then
    printf '%s\n' 'wslview: Linux target does not exist' >&2
    exit 1
  fi
  if ! target=$(@wslpathCommand@ -w "$absolute") || [[ -z $target ]]; then
    printf '%s\n' 'wslview: could not convert the Linux target to a Windows path' >&2
    exit 1
  fi
fi

encoded=$(printf '%s' "$target" | @base64Command@ --wrap=0)
script="\$ErrorActionPreference = 'Stop'; try { \$target = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encoded')); \$start = New-Object System.Diagnostics.ProcessStartInfo; \$start.FileName = \$target; \$start.UseShellExecute = \$true; [Diagnostics.Process]::Start(\$start) | Out-Null; exit 0 } catch { [Console]::Error.WriteLine('wslview: Windows could not open the target'); exit 1 }"
exec @powershellCommand@ -NoLogo -NoProfile -NonInteractive -Command "$script"
