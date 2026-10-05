# shellcheck shell=bash

docker_command=@dockerCommand@
label_key=@labelKey@
label_value=@labelValue@
minimum_age_seconds=@minimumAgeSeconds@

# 空の値で tab の連続が一つに潰れるため label を最後以外の列に置く形は不可
printf -v format '{{.ID}}\t{{.State}}\t{{.CreatedAt}}\t{{.Label "%s"}}' "$label_key"
listing=$("$docker_command" container ls --all --no-trunc --format "$format")
now=$(date +%s)

stale=()
while IFS=$'\t' read -r id state created managed; do
  [[ -n $id && $managed == "$label_value" ]] || continue
  # 所有者の生死を判定できないため running の回収は不可
  case $state in
    created | exited | dead) ;;
    *) continue ;;
  esac
  # 末尾の zone 名を date が読めないため CreatedAt のままの解析は不可
  created_at=$(date --date="${created% *}" +%s)
  # 作成から start までの途中の container を消すため年齢の下限なしの回収は不可
  ((now - created_at >= minimum_age_seconds)) || continue
  stale+=("$id")
done <<<"$listing"

((${#stale[@]} > 0)) || exit 0
printf 'removing stopped testcontainers container %s\n' "${stale[@]}"
# 匿名 volume が残るため docker container prune は不可
# 一覧の後に start された container を消すため --force は不可
"$docker_command" container rm --volumes "${stale[@]}" >/dev/null
