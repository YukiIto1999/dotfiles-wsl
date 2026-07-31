# Frozen pre-migration behavior used to prove old/new generation interoperability.
dotfiles_oci_ensure_lock_file() {
  local state_root=$1 lock_file temporary
  lock_file=$state_root/operation.lock
  if [[ ! -e $lock_file && ! -L $lock_file ]]; then
    temporary=$(mktemp "$state_root/.operation-lock.XXXXXX") || return 1
    chmod 0600 "$temporary" || return 1
    if ! ln -- "$temporary" "$lock_file" 2>/dev/null \
      && [[ ! -e $lock_file && ! -L $lock_file ]]; then
      rm -f -- "$temporary"
      return 1
    fi
    rm -f -- "$temporary" || return 1
    sync "$state_root" || return 1
  fi
}

dotfiles_oci_acquire_image_lock() {
  local state_root=$1 expected_uid=$2 expected_gid=$3 lock_kind=$4
  local lock_file=$state_root/operation.lock fd_path path_metadata fd_metadata
  local _device _inode lock_uid lock_gid lock_mode lock_links

  [[ $lock_kind == shared || $lock_kind == exclusive ]] || return 2
  [[ -f $lock_file && ! -L $lock_file ]] || return 2
  exec {DOTFILES_OCI_IMAGE_LOCK_FD}< "$lock_file" || return 2
  fd_path=/proc/$$/fd/$DOTFILES_OCI_IMAGE_LOCK_FD
  path_metadata=$(stat -c '%d|%i|%u|%g|%a|%h' -- "$lock_file") || return 2
  fd_metadata=$(stat -Lc '%d|%i|%u|%g|%a|%h' -- "$fd_path") || return 2
  [[ $path_metadata == "$fd_metadata" ]] || return 2
  IFS='|' read -r _device _inode lock_uid lock_gid lock_mode lock_links <<< "$fd_metadata"
  [[ $lock_uid == "$expected_uid" && $lock_gid == "$expected_gid" \
    && $lock_mode == 600 && $lock_links == 1 ]] || return 2
  if [[ $lock_kind == shared ]]; then
    flock --shared --nonblock "$DOTFILES_OCI_IMAGE_LOCK_FD"
  else
    flock --exclusive --nonblock "$DOTFILES_OCI_IMAGE_LOCK_FD"
  fi
}
