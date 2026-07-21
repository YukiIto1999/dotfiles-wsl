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

dotfiles_oci_release_image_lock() {
  if [[ -n ${DOTFILES_OCI_IMAGE_LEGACY_LOCK_FD:-} ]]; then
    exec {DOTFILES_OCI_IMAGE_LEGACY_LOCK_FD}<&-
    unset DOTFILES_OCI_IMAGE_LEGACY_LOCK_FD
  fi
  if [[ -n ${DOTFILES_OCI_IMAGE_DIRECTORY_LOCK_FD:-} ]]; then
    exec {DOTFILES_OCI_IMAGE_DIRECTORY_LOCK_FD}<&-
    unset DOTFILES_OCI_IMAGE_DIRECTORY_LOCK_FD
  fi
}

# Returns 1 when a valid lock is busy and 2 when the lock contract is invalid.
dotfiles_oci_acquire_image_lock() {
  local state_root=$1 expected_uid=$2 expected_gid=$3 lock_kind=$4 bootstrap_mode=${5:-existing-only}
  local lock_file directory_fd_path directory_path_metadata directory_fd_metadata
  local lock_fd_path lock_path_metadata lock_fd_metadata temporary publication_status
  local entry name metadata legacy_temp='' new_temp='' residue_count=0
  local _device _inode lock_uid lock_gid lock_mode lock_links lock_size

  [[ $lock_kind == shared || $lock_kind == exclusive ]] || return 2
  [[ $bootstrap_mode == create || $bootstrap_mode == existing-only ]] || return 2
  [[ $lock_kind == exclusive || $bootstrap_mode == existing-only ]] || return 2
  dotfiles_oci_validate_state_root "$state_root" "$expected_uid" "$expected_gid" || return 2
  directory_path_metadata=$(stat -c '%d|%i|%u|%g|%a' -- "$state_root") || return 2
  exec {DOTFILES_OCI_IMAGE_DIRECTORY_LOCK_FD}< "$state_root" || return 2
  directory_fd_path=/proc/$BASHPID/fd/$DOTFILES_OCI_IMAGE_DIRECTORY_LOCK_FD
  directory_fd_metadata=$(stat -Lc '%d|%i|%u|%g|%a' -- "$directory_fd_path") || {
    dotfiles_oci_release_image_lock
    return 2
  }
  [[ $directory_path_metadata == "$directory_fd_metadata" ]] || {
    dotfiles_oci_release_image_lock
    return 2
  }
  if [[ $lock_kind == shared ]]; then
    flock --shared --nonblock "$DOTFILES_OCI_IMAGE_DIRECTORY_LOCK_FD" || {
      dotfiles_oci_release_image_lock
      return 1
    }
  elif ! flock --exclusive --nonblock "$DOTFILES_OCI_IMAGE_DIRECTORY_LOCK_FD"; then
    dotfiles_oci_release_image_lock
    return 1
  fi
  if ! dotfiles_oci_validate_state_root "$state_root" "$expected_uid" "$expected_gid" \
    || [[ $(stat -c '%d|%i|%u|%g|%a' -- "$state_root") != "$directory_fd_metadata" ]]; then
    dotfiles_oci_release_image_lock
    return 2
  fi

  lock_file=$state_root/operation.lock
  for entry in "$state_root"/.operation-lock*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    (( residue_count += 1 ))
    [[ $residue_count -eq 1 && -f $entry && ! -L $entry ]] || {
      dotfiles_oci_release_image_lock
      return 2
    }
    metadata=$(stat -c '%u|%g|%a|%h|%s' -- "$entry") || {
      dotfiles_oci_release_image_lock
      return 2
    }
    case $name in
      .operation-lock.??????)
        [[ $name =~ ^\.operation-lock\.[A-Za-z0-9]{6}$ &&
          $metadata == "$expected_uid|$expected_gid|600|2|0" ]] || {
          dotfiles_oci_release_image_lock
          return 2
        }
        legacy_temp=$entry
        ;;
      .operation-lock-bootstrap.??????)
        [[ $name =~ ^\.operation-lock-bootstrap\.[A-Za-z0-9]{6}$ &&
          $metadata == "$expected_uid|$expected_gid|600|1|0" ]] || {
          dotfiles_oci_release_image_lock
          return 2
        }
        new_temp=$entry
        ;;
      *)
        dotfiles_oci_release_image_lock
        return 2
        ;;
    esac
  done
  if [[ $bootstrap_mode == existing-only && $residue_count -ne 0 ]]; then
    dotfiles_oci_release_image_lock
    return 2
  fi

  if [[ ! -e $lock_file && ! -L $lock_file ]]; then
    [[ -z $legacy_temp ]] || {
      dotfiles_oci_release_image_lock
      return 2
    }
    if [[ $bootstrap_mode == existing-only ]]; then
      dotfiles_oci_release_image_lock
      return 2
    fi
    if [[ -n $new_temp ]]; then
      temporary=$new_temp
    else
      temporary=$(mktemp "$state_root/.operation-lock-bootstrap.XXXXXX") || {
        dotfiles_oci_release_image_lock
        return 2
      }
      new_temp=$temporary
      chmod 0600 "$temporary" || {
        rm -f -- "$temporary"
        sync "$state_root" || true
        dotfiles_oci_release_image_lock
        return 2
      }
    fi
    publication_status=0
    dotfiles_atomic_publish_no_replace "$temporary" "$lock_file" "$state_root" || \
      publication_status=$?
    if [[ $publication_status -ne 0 && $publication_status -ne 2 ]]; then
      dotfiles_oci_release_image_lock
      return 2
    fi
  fi

  [[ -f $lock_file && ! -L $lock_file ]] || {
    dotfiles_oci_release_image_lock
    return 2
  }
  lock_path_metadata=$(stat -c '%d|%i|%u|%g|%a|%h|%s' -- "$lock_file") || {
    dotfiles_oci_release_image_lock
    return 2
  }
  IFS='|' read -r _device _inode lock_uid lock_gid lock_mode lock_links lock_size \
    <<< "$lock_path_metadata"
  [[ $lock_uid == "$expected_uid" && $lock_gid == "$expected_gid" &&
    $lock_mode == 600 && $lock_size == 0 ]] || {
    dotfiles_oci_release_image_lock
    return 2
  }
  if [[ -n $legacy_temp ]]; then
    [[ $lock_links == 2 &&
      $(stat -c '%d|%i' -- "$legacy_temp") == "$_device|$_inode" ]] || {
      dotfiles_oci_release_image_lock
      return 2
    }
  elif [[ $lock_links != 1 ]]; then
    dotfiles_oci_release_image_lock
    return 2
  fi

  exec {DOTFILES_OCI_IMAGE_LEGACY_LOCK_FD}< "$lock_file" || {
    dotfiles_oci_release_image_lock
    return 2
  }
  lock_fd_path=/proc/$BASHPID/fd/$DOTFILES_OCI_IMAGE_LEGACY_LOCK_FD
  lock_fd_metadata=$(stat -Lc '%d|%i|%u|%g|%a|%h|%s' -- "$lock_fd_path") || {
    dotfiles_oci_release_image_lock
    return 2
  }
  [[ $lock_path_metadata == "$lock_fd_metadata" ]] || {
    dotfiles_oci_release_image_lock
    return 2
  }
  if [[ $lock_kind == shared ]]; then
    flock --shared --nonblock "$DOTFILES_OCI_IMAGE_LEGACY_LOCK_FD" || {
      dotfiles_oci_release_image_lock
      return 1
    }
  elif ! flock --exclusive --nonblock "$DOTFILES_OCI_IMAGE_LEGACY_LOCK_FD"; then
    dotfiles_oci_release_image_lock
    return 1
  fi
  [[ $(stat -c '%d|%i|%u|%g|%a|%h|%s' -- "$lock_file") == "$lock_fd_metadata" ]] || {
    dotfiles_oci_release_image_lock
    return 2
  }

  if [[ $bootstrap_mode == create && -n $legacy_temp ]]; then
    [[ $(stat -c '%d|%i|%u|%g|%a|%h|%s' -- "$legacy_temp") == "$lock_fd_metadata" ]] || {
      dotfiles_oci_release_image_lock
      return 2
    }
    rm -- "$legacy_temp" || {
      dotfiles_oci_release_image_lock
      return 2
    }
    sync "$state_root" || {
      dotfiles_oci_release_image_lock
      return 2
    }
  elif [[ $bootstrap_mode == create && -n $new_temp && -e $new_temp ]]; then
    metadata=$(stat -c '%u|%g|%a|%h|%s' -- "$new_temp") || {
      dotfiles_oci_release_image_lock
      return 2
    }
    [[ $metadata == "$expected_uid|$expected_gid|600|1|0" ]] || {
      dotfiles_oci_release_image_lock
      return 2
    }
    rm -- "$new_temp" || {
      dotfiles_oci_release_image_lock
      return 2
    }
    sync "$state_root" || {
      dotfiles_oci_release_image_lock
      return 2
    }
  fi
  metadata=$(stat -c '%d|%i|%u|%g|%a|%h|%s' -- "$lock_file") || {
    dotfiles_oci_release_image_lock
    return 2
  }
  [[ $metadata == "$_device|$_inode|$expected_uid|$expected_gid|600|1|0" ]] || {
    dotfiles_oci_release_image_lock
    return 2
  }
}
