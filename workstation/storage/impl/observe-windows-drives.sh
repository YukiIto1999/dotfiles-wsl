set -euo pipefail

df_command=@dfCommand@

# WSL は Windows の drive を drvfs の 9p として mount し、source を drive の root（C:\）にする。
# drive の下の directory を別に mount した source は drive ではないので数えない
if ! listing=$("$df_command" -t 9p --block-size=1K --output=source,size,avail 2>/dev/null); then
  exit 1
fi

declare -A seen=()
measurements=()
while read -r source size avail; do
  [[ $source =~ ^([A-Za-z]):\\$ ]] || continue
  letter=${BASH_REMATCH[1],,}
  [[ -v seen[$letter] ]] && continue
  seen[$letter]=1
  [[ $size =~ ^[0-9]+$ && $avail =~ ^[0-9]+$ ]] && ((size > 0)) || exit 1
  measurements+=("$letter $((avail * 100 / size))")
done < <(tail -n +2 <<<"$listing")

((${#measurements[@]} > 0)) || exit 1
printf '%s\n' "${measurements[@]}"
