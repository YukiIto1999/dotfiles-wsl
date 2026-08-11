usage() {
  cat <<'USAGE'
usage: dotfiles-cleanup [--delete] [--system] [--vscode-server]

Without --delete, prints cleanup targets only.
With --delete, removes Home Manager backups below the configured home directory.
With --system, selects only /etc/nixos backup/failure leftovers.
With --vscode-server, also removes ~/.vscode-server so VS Code Remote WSL reinstalls it.
Home deletion refuses root; system deletion requires root.
USAGE
}

delete=0
system=0
vscode=0
configured_home=@homeDir@
current_home_files=@currentHomeFiles@
current_backup_extension=@currentBackupExtension@
current_uses_backup_extension=@currentUsesBackupExtension@
system_profile=@systemProfilePath@
system_root=@systemRoot@
nix_store=@nixStoreDir@
declare -A seen_paths=()
declare -A seen_generation_contracts=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete) delete=1 ;;
    --system) system=1 ;;
    --vscode-server) vscode=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ $system -eq 1 && $vscode -eq 1 ]]; then
  echo "--system cannot be combined with --vscode-server" >&2
  exit 2
fi
if [[ $delete -eq 1 && $system -eq 1 && $EUID -ne 0 ]]; then
  echo "system deletion must run as root" >&2
  exit 1
fi
if [[ $delete -eq 1 && $system -eq 0 && $EUID -eq 0 ]]; then
  echo "home deletion must not run as root" >&2
  exit 1
fi

remove_path() {
  local path=$1
  [[ ${seen_paths["$path"]+present} ]] && return 0
  seen_paths["$path"]=1
  [[ -e $path || -L $path ]] || return 0
  if [[ $delete -eq 1 ]]; then
    rm -rf -- "$path"
    echo "removed $path"
  else
    echo "would remove $path"
  fi
}

remove_generation_backups() {
  local generation=$1 extension=$2 generation_name home_files relative contract
  generation_name=${generation##*/}
  [[ ${generation%/*} == "$nix_store" ]] || return 1
  [[ $generation_name =~ ^[0-9a-z]{32}-home-manager-generation$ ]] || return 1
  [[ $extension =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  contract="$configured_home|$generation|$extension"
  [[ ${seen_generation_contracts["$contract"]+present} ]] && return 0
  home_files=$(readlink -e -- "$generation/home-files") || return 1
  [[ $home_files == "$generation/home-files" || ${home_files%/*} == "$nix_store" ]] || return 1
  seen_generation_contracts["$contract"]=1
  while IFS= read -r -d '' relative; do
    remove_path "$configured_home/$relative.$extension"
  done < <(find "$home_files" \( -type f -o -type l \) -printf '%P\0')
}

shopt -s nullglob

if [[ $system -eq 1 ]]; then
  for path in "$system_root"/nixos.bak.* "$system_root"/nixos.failed.*; do
    remove_path "$path"
  done
  exit 0
fi

if [[ $current_uses_backup_extension -eq 1 ]]; then
  if ! remove_generation_backups "${current_home_files%/home-files}" "$current_backup_extension"; then
    echo "current Home Manager generation is unavailable" >&2
    exit 1
  fi
fi

for profile in "$system_profile" "$system_profile"-*-link; do
  [[ -L $profile ]] || continue
  unit="$profile/etc/systemd/system/home-manager-@username@.service"
  [[ -f $unit ]] || continue
  grep -Fq 'Environment="HOME_MANAGER_BACKUP_COMMAND=' "$unit" && continue
  generation=$(sed -nE 's|^ExecStart=[^ ]+ ([^ ]+-home-manager-generation)$|\1|p' "$unit")
  historical_extension=$(sed -nE 's|^Environment="HOME_MANAGER_BACKUP_EXT=([A-Za-z0-9][A-Za-z0-9._-]*)"$|\1|p' "$unit")
  historical_home=$(sed -nE 's|^RequiresMountsFor=(/[^ ]*)$|\1|p' "$unit")
  [[ $historical_home == "$configured_home" ]] || continue
  remove_generation_backups "$generation" "$historical_extension" || continue
done

if [[ $vscode -eq 1 ]]; then
  remove_path "$configured_home/.vscode-server"
fi
