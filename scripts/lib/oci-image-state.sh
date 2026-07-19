dotfiles_oci_validate_state_directory() {
  local directory=$1 expected_uid=$2 expected_gid=$3 metadata
  [[ -d $directory && ! -L $directory ]] || return 1
  metadata=$(stat -c '%u|%g|%a' -- "$directory") || return 1
  [[ $metadata == "$expected_uid|$expected_gid|700" ]]
}

dotfiles_oci_validate_state_root() {
  local state_root=$1 expected_uid=$2 expected_gid=$3
  dotfiles_oci_validate_state_directory "$state_root" "$expected_uid" "$expected_gid" \
    && dotfiles_oci_validate_state_directory "$state_root/receipts" "$expected_uid" "$expected_gid"
}

# shellcheck disable=SC2329 # Shared library: only the synchronization command creates state.
dotfiles_oci_prepare_state_root() {
  local state_root=$1 expected_uid=$2 expected_gid=$3 directory parent
  for directory in "$state_root" "$state_root/receipts"; do
    if [[ ! -e $directory && ! -L $directory ]]; then
      parent=${directory%/*}
      mkdir -p -- "$directory" || return 1
      chmod 0700 -- "$directory" || return 1
      sync "$parent" || return 1
    fi
    dotfiles_oci_validate_state_directory "$directory" "$expected_uid" "$expected_gid" || return 1
  done
}

# shellcheck disable=SC2329 # Shared library: only the synchronization command creates a lock file.
dotfiles_oci_ensure_lock_file() {
  local state_root=$1 lock_file temporary
  lock_file=$state_root/operation.lock
  if [[ ! -e $lock_file && ! -L $lock_file ]]; then
    temporary=$(mktemp "$state_root/.operation-lock.XXXXXX") || return 1
    if ! chmod 0600 "$temporary"; then
      rm -f -- "$temporary"
      return 1
    fi
    if ! ln -- "$temporary" "$lock_file" 2>/dev/null \
      && [[ ! -e $lock_file && ! -L $lock_file ]]; then
      rm -f -- "$temporary"
      return 1
    fi
    rm -f -- "$temporary" || return 1
    sync "$state_root" || return 1
  fi
}

# Returns 1 when a valid lock is busy and 2 when the lock contract is invalid.
dotfiles_oci_acquire_image_lock() {
  local state_root=$1 expected_uid=$2 expected_gid=$3 lock_kind=$4
  local lock_file=$state_root/operation.lock fd_path path_metadata fd_metadata
  local _device _inode lock_uid lock_gid lock_mode lock_links

  [[ $lock_kind == shared || $lock_kind == exclusive ]] || return 2
  [[ -f $lock_file && ! -L $lock_file ]] || return 2
  exec {DOTFILES_OCI_IMAGE_LOCK_FD}< "$lock_file" || return 2
  fd_path=/proc/$$/fd/$DOTFILES_OCI_IMAGE_LOCK_FD
  if [[ ! -f $lock_file || -L $lock_file || ! -f $fd_path ]]; then
    dotfiles_oci_release_image_lock
    return 2
  fi
  path_metadata=$(stat -c '%d|%i|%u|%g|%a|%h' -- "$lock_file") || {
    dotfiles_oci_release_image_lock
    return 2
  }
  fd_metadata=$(stat -Lc '%d|%i|%u|%g|%a|%h' -- "$fd_path") || {
    dotfiles_oci_release_image_lock
    return 2
  }
  if [[ $path_metadata != "$fd_metadata" ]]; then
    dotfiles_oci_release_image_lock
    return 2
  fi
  IFS='|' read -r _device _inode lock_uid lock_gid lock_mode lock_links <<< "$fd_metadata"
  if [[ $lock_uid != "$expected_uid" || $lock_gid != "$expected_gid" \
    || $lock_mode != 600 || $lock_links != 1 ]]; then
    dotfiles_oci_release_image_lock
    return 2
  fi

  if [[ $lock_kind == shared ]]; then
    if ! flock --shared --nonblock "$DOTFILES_OCI_IMAGE_LOCK_FD"; then
      dotfiles_oci_release_image_lock
      return 1
    fi
  else
    if ! flock --exclusive --nonblock "$DOTFILES_OCI_IMAGE_LOCK_FD"; then
      dotfiles_oci_release_image_lock
      return 1
    fi
  fi

  if [[ ! -f $lock_file || -L $lock_file ]]; then
    dotfiles_oci_release_image_lock
    return 2
  fi
  path_metadata=$(stat -c '%d|%i|%u|%g|%a|%h' -- "$lock_file") || {
    dotfiles_oci_release_image_lock
    return 2
  }
  if [[ $path_metadata != "$fd_metadata" ]]; then
    dotfiles_oci_release_image_lock
    return 2
  fi
}

dotfiles_oci_release_image_lock() {
  if [[ -n ${DOTFILES_OCI_IMAGE_LOCK_FD:-} ]]; then
    exec {DOTFILES_OCI_IMAGE_LOCK_FD}<&-
    unset DOTFILES_OCI_IMAGE_LOCK_FD
  fi
}
