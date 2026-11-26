#!/usr/bin/env bash
# dotfiles-doctor: a short list of checks that each name an action. Exit 1 when any check fails.
set -uo pipefail

repo=@dotfilesDir@
minimum_free_gib=@minimumFreeGiB@
hindsight_url=@hindsightUrl@
standard_clone=@standardClone@

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
warn() { printf 'WARN  %s\n      -> %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s\n      -> %s\n' "$1" "$2"; failures=$((failures + 1)); }

# 1. The running system is built from the checkout's HEAD.
running=$(nixos-version --configuration-revision 2>/dev/null || true)
head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
if [ -z "$head" ]; then
  warn "checkout $repo is not readable" "clone the repository there or fix the path in the host profile"
elif [ "$running" = "$head" ]; then
  pass "running system is built from HEAD ${head:0:12}"
else
  warn "running system revision ${running:-unknown} differs from HEAD ${head:0:12}" "run dotfiles-rebuild after committing"
fi

# 2. Failed units, system and user.
failed_system=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ')
failed_user=$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ')
if [ -z "$failed_system$failed_user" ]; then
  pass "no failed systemd units"
else
  fail "failed units: ${failed_system:-} ${failed_user:-}" "journalctl -u UNIT (system) or journalctl --user -u UNIT (user) shows the cause"
fi

# 3. Disk space for the root filesystem, which holds /nix/store.
free_gib=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
if [ "${free_gib:-0}" -ge "$minimum_free_gib" ]; then
  pass "${free_gib} GiB free on /"
else
  fail "${free_gib} GiB free on / (threshold ${minimum_free_gib} GiB)" "nix-collect-garbage --delete-older-than 14d; clear large caches in ~/.cache"
fi

# 4. Memory pressure: sustained full stalls mean work is waiting on memory.
full_avg60=$(awk '/^full/ { for (i = 1; i <= NF; i++) if ($i ~ /^avg60=/) { sub("avg60=", "", $i); print $i } }' /proc/pressure/memory 2>/dev/null)
if awk -v value="${full_avg60:-0}" 'BEGIN { exit !(value < 10) }'; then
  pass "memory pressure full avg60 ${full_avg60:-0}%"
else
  warn "memory pressure full avg60 ${full_avg60}%" "check the largest consumers: systemd-cgtop -m; agent sessions live in agents.slice"
fi

# 5. WSL connection health. A failed 512 KiB VMBus ring allocation leaves a Relay waiting forever and new
#    wsl.exe connections hang; the cause is a lack of contiguous free memory in the guest.
ring_frames=$(journalctl -k -b 0 -q --no-pager -o cat --grep='vmbus_alloc_ring\+0x' 2>/dev/null | wc -l)
stuck_relays=$(ps -e -o ppid=,etimes=,comm= | awk '$1 == 1 && $3 == "Relay" && $2 >= 300 { n++ } END { print n + 0 }')
if [ "$ring_frames" -eq 0 ] && [ "$stuck_relays" -eq 0 ]; then
  pass "no VMBus ring allocation failures and no stuck WSL relays this boot"
else
  warn "this boot has $ring_frames vmbus_alloc_ring stack frames and $stuck_relays stuck Relay processes" \
    "if new WSL terminals hang, close idle agent sessions to free memory; a WSL restart clears it"
fi

# 6. Agent sessions started before the redesign still use the transition commands.
old_sessions=$(pgrep -fc 'impl/supervise\.py' || true)
if [ "${old_sessions:-0}" -eq 0 ]; then
  pass "no session of the old agent runtime is running; agents/transition.nix can be deleted"
else
  warn "$old_sessions session(s) of the old agent runtime are running" "in each: /exit, then omp --resume; then delete agents/transition.nix"
fi

# 7. Leftover processes in agent scopes whose client has exited.
slice_cgroup=$(systemctl --user show -P ControlGroup agents.slice 2>/dev/null)
if [ -n "$slice_cgroup" ]; then
  for scope_dir in /sys/fs/cgroup"$slice_cgroup"/*.scope; do
    procs="$scope_dir/cgroup.procs"
    [ -r "$procs" ] || continue
    comms=$(xargs -r -I{} cat /proc/{}/comm <"$procs" 2>/dev/null | sort -u | paste -sd' ')
    [ -n "$comms" ] || continue
    case " $comms " in
      *" omp "* | *" claude "* | *" codex "* | *" opencode "* | *" agy "*) continue ;;
    esac
    # The OMP worker daemon is shared by all sessions and stays in the scope of the session that started it.
    if xargs -r -I{} cat /proc/{}/cmdline <"$procs" 2>/dev/null | tr '\0' ' ' | grep -q __omp_worker_daemon; then
      continue
    fi
    scope=${scope_dir##*/}
    warn "$scope has processes after its agent exited: $comms" "systemctl --user stop $scope"
  done
fi

# 8. Knowledge services.
if curl -fsS -m 5 "$hindsight_url/health" >/dev/null 2>&1; then
  pass "Hindsight answers at $hindsight_url"
else
  fail "Hindsight does not answer at $hindsight_url" "systemctl status docker-hindsight.service"
fi

# 9. Scheduled agent jobs: a failed last run is a failure until the next success.
for unit in $(systemctl --user list-units --all --no-legend --plain 'dotfiles-*.service' 2>/dev/null | awk '{print $1}'); do
  result=$(systemctl --user show -P Result "$unit")
  last=$(systemctl --user show -P ExecMainStartTimestamp "$unit")
  if [ "$result" = success ]; then
    pass "$unit last run ${last:-never}: success"
  else
    fail "$unit last run $last: $result" "journalctl --user -u $unit -n 20"
  fi
done

# 10. The architecture-standard clone is refreshed daily.
if [ -d "$standard_clone/.git" ]; then
  fetched=$(stat -c %Y "$standard_clone/.git/FETCH_HEAD" 2>/dev/null || stat -c %Y "$standard_clone/.git/HEAD")
  age_hours=$((($(date +%s) - fetched) / 3600))
  if [ "$age_hours" -le 48 ]; then
    pass "architecture-standard clone fetched ${age_hours}h ago"
  else
    warn "architecture-standard clone fetched ${age_hours}h ago" "dotfiles-standard-sync"
  fi
else
  warn "architecture-standard clone missing at $standard_clone" "dotfiles-standard-sync"
fi

exit $((failures > 0))
