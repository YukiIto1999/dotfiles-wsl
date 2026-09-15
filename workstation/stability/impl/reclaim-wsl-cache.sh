set -euo pipefail

meminfo_path=${WSL_MEMORY_RECLAIM_MEMINFO_PATH:-/proc/meminfo}
uptime_path=${WSL_MEMORY_RECLAIM_UPTIME_PATH:-/proc/uptime}
drop_caches_path=${WSL_MEMORY_RECLAIM_DROP_CACHES_PATH:-/proc/sys/vm/drop_caches}
state_directory=${WSL_MEMORY_RECLAIM_STATE_DIRECTORY:-/run/dotfiles-wsl-memory-reclaim}
state_path=$state_directory/last-success-uptime-seconds
elapsed_seconds=${WSL_MEMORY_RECLAIM_ELAPSED_SECONDS:-}
minimum_free_percent=@minimumFreePercent@
minimum_clean_page_cache_kib=@minimumCleanPageCacheKiB@
cooldown_seconds=@cooldownSeconds@

fail() {
  printf 'WSL cache reclaim failed: %s\n' "$1" >&2
  exit 1
}

is_safe_decimal() {
  # 16桁までなら、百分率計算を含む後続の符号付き64bit算術がオーバーフローしない。
  [[ $1 =~ ^(0|[1-9][0-9]{0,15})$ ]]
}

read_metric() {
  awk -v key="$1:" '$1 == key { print $2; exit }' "$meminfo_path"
}

if [[ -z $elapsed_seconds ]]; then
  if [[ ! -r $uptime_path ]]; then
    fail "uptime interface unavailable"
  fi
  uptime_value=$(awk '{ print $1; exit }' "$uptime_path") ||
    fail "could not read uptime"
  elapsed_seconds=${uptime_value%%.*}
fi

if [[ ! -r $meminfo_path || ! -w $drop_caches_path ]]; then
  fail "memory interface unavailable"
fi

mem_total_kib=$(read_metric MemTotal)
mem_free_kib=$(read_metric MemFree)
cached_kib=$(read_metric Cached)
shmem_kib=$(read_metric Shmem)
dirty_kib=$(read_metric Dirty)
writeback_kib=$(read_metric Writeback)

for metric in \
  "$mem_total_kib" \
  "$mem_free_kib" \
  "$cached_kib" \
  "$shmem_kib" \
  "$dirty_kib" \
  "$writeback_kib"; do
  if ! is_safe_decimal "$metric"; then
    fail "invalid memory observation"
  fi
done
if ! is_safe_decimal "$elapsed_seconds"; then
  fail "invalid uptime observation"
fi
if ((mem_total_kib == 0)); then
  fail "zero total memory"
fi
if [[ -e $state_path ]]; then
  if [[ ! -r $state_path ]]; then
    fail "cooldown state unavailable"
  fi
  last_success=$(<"$state_path")
  if ! is_safe_decimal "$last_success"; then
    fail "invalid cooldown state"
  fi
  if ((elapsed_seconds < last_success)); then
    fail "monotonic clock moved backwards"
  fi
fi

free_percent=$((mem_free_kib * 100 / mem_total_kib))
file_page_cache_kib=$((cached_kib > shmem_kib ? cached_kib - shmem_kib : 0))
non_clean_page_cache_kib=$((dirty_kib + writeback_kib))
clean_page_cache_kib=$((
  file_page_cache_kib > non_clean_page_cache_kib
    ? file_page_cache_kib - non_clean_page_cache_kib
    : 0
))

if ((free_percent >= minimum_free_percent)); then
  exit 0
fi
if ((clean_page_cache_kib < minimum_clean_page_cache_kib)); then
  exit 0
fi

if [[ -v last_success ]] && ((elapsed_seconds - last_success < cooldown_seconds)); then
  exit 0
fi

# sync はdirty pageのI/Oでactive sessionを止め得るため、clean page cacheだけを回収する。
printf '1\n' > "$drop_caches_path"
mkdir -p "$state_directory"
state_tmp=${state_path}.tmp
printf '%s\n' "$elapsed_seconds" > "$state_tmp"
mv -fT "$state_tmp" "$state_path"
printf 'WSL cache reclaimed: free=%s%% clean-page-cache=%sKiB\n' "$free_percent" "$clean_page_cache_kib"
