set -euo pipefail

df_command=@dfCommand@

mounts_file=@mountsFile@

# 対象外の9pのstat失敗が全driveの観測を止めるためdfの一括照会は不採用

declare -A seen=()
measurements=()
while read -r source target filesystem _; do
  [[ $filesystem = 9p ]] || continue
  printf -v source '%b' "$source"
  [[ $source =~ ^([A-Za-z]):\\$ ]] || continue
  letter=${BASH_REMATCH[1],,}
  [[ -v seen[$letter] ]] && continue
  seen[$letter]=1
  printf -v target '%b' "$target"
  if ! listing=$("$df_command" --block-size=1K --output=size,avail -- "$target" 2>/dev/null); then
    exit 1
  fi
  read -r size avail <<<"${listing#*$'\n'}"
  [[ $size =~ ^[0-9]+$ && $avail =~ ^[0-9]+$ ]] && ((size > 0)) || exit 1
  measurements+=("$letter $((avail * 100 / size))")
done < "$mounts_file"

((${#measurements[@]} > 0)) || exit 1
printf '%s\n' "${measurements[@]}"
