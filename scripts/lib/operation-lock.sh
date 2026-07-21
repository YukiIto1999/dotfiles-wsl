dotfiles_release_operation_lock() {
  if [[ -n ${DOTFILES_OPERATION_LEGACY_LOCK_FD:-} ]]; then
    exec {DOTFILES_OPERATION_LEGACY_LOCK_FD}<&-
    unset DOTFILES_OPERATION_LEGACY_LOCK_FD
  fi
  if [[ -n ${DOTFILES_OPERATION_DIRECTORY_LOCK_FD:-} ]]; then
    exec {DOTFILES_OPERATION_DIRECTORY_LOCK_FD}<&-
    unset DOTFILES_OPERATION_DIRECTORY_LOCK_FD
  fi
}

dotfiles_acquire_operation_lock() {
  local common_git_dir=$1 expected_uid=$2 expected_gid=$3 bootstrap_mode=${4:-create}
  local lock_file directory_fd_path directory_path_metadata directory_fd_metadata
  local lock_fd_path lock_path_metadata lock_fd_metadata temporary publication_status
  local entry name metadata legacy_temp='' new_temp='' residue_count=0
  local _device _inode directory_uid directory_gid lock_uid lock_gid lock_mode lock_links lock_size

  [[ $bootstrap_mode == create || $bootstrap_mode == existing-only ]] || return 1
  [[ $common_git_dir == /* && -d $common_git_dir && ! -L $common_git_dir ]] || {
    echo 'dotfiles-operation-lock: Git common directory must be an absolute real directory' >&2
    return 1
  }
  directory_path_metadata=$(stat -c '%d|%i|%u|%g' -- "$common_git_dir") || return 1
  IFS='|' read -r _device _inode directory_uid directory_gid <<< "$directory_path_metadata"
  [[ $directory_uid == "$expected_uid" && $directory_gid == "$expected_gid" ]] || {
    echo 'dotfiles-operation-lock: Git common directory has an unexpected owner' >&2
    return 1
  }
  exec {DOTFILES_OPERATION_DIRECTORY_LOCK_FD}< "$common_git_dir" || return 1
  directory_fd_path=/proc/$BASHPID/fd/$DOTFILES_OPERATION_DIRECTORY_LOCK_FD
  directory_fd_metadata=$(stat -Lc '%d|%i|%u|%g' -- "$directory_fd_path") || {
    dotfiles_release_operation_lock
    return 1
  }
  [[ $directory_path_metadata == "$directory_fd_metadata" ]] || {
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: Git common directory changed while opening it' >&2
    return 1
  }
  flock --exclusive --nonblock "$DOTFILES_OPERATION_DIRECTORY_LOCK_FD" || {
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: another dotfiles state transition is running' >&2
    return 1
  }
  [[ -d $common_git_dir && ! -L $common_git_dir &&
    $(stat -c '%d|%i|%u|%g' -- "$common_git_dir") == "$directory_fd_metadata" ]] || {
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: Git common directory changed after acquisition' >&2
    return 1
  }

  lock_file=$common_git_dir/dotfiles-operation.lock
  for entry in "$common_git_dir"/.dotfiles-operation*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    (( residue_count += 1 ))
    [[ $residue_count -eq 1 && -f $entry && ! -L $entry ]] || {
      dotfiles_release_operation_lock
      echo 'dotfiles-operation-lock: lock publication residue is invalid' >&2
      return 1
    }
    metadata=$(stat -c '%u|%g|%a|%h|%s' -- "$entry") || {
      dotfiles_release_operation_lock
      return 1
    }
    case $name in
      .dotfiles-operation.??????)
        [[ $name =~ ^\.dotfiles-operation\.[A-Za-z0-9]{6}$ &&
          $metadata == "$expected_uid|$expected_gid|600|2|0" ]] || {
          dotfiles_release_operation_lock
          echo 'dotfiles-operation-lock: legacy lock publication residue is invalid' >&2
          return 1
        }
        legacy_temp=$entry
        ;;
      .dotfiles-operation-bootstrap.??????)
        [[ $name =~ ^\.dotfiles-operation-bootstrap\.[A-Za-z0-9]{6}$ &&
          $metadata == "$expected_uid|$expected_gid|600|1|0" ]] || {
          dotfiles_release_operation_lock
          echo 'dotfiles-operation-lock: lock bootstrap residue is invalid' >&2
          return 1
        }
        new_temp=$entry
        ;;
      *)
        dotfiles_release_operation_lock
        echo 'dotfiles-operation-lock: unknown lock publication residue' >&2
        return 1
        ;;
    esac
  done
  if [[ $bootstrap_mode == existing-only && $residue_count -ne 0 ]]; then
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: lock publication is incomplete' >&2
    return 1
  fi

  if [[ ! -e $lock_file && ! -L $lock_file ]]; then
    [[ -z $legacy_temp ]] || {
      dotfiles_release_operation_lock
      echo 'dotfiles-operation-lock: legacy residue has no canonical lock' >&2
      return 1
    }
    if [[ $bootstrap_mode == existing-only ]]; then
      dotfiles_release_operation_lock
      echo 'dotfiles-operation-lock: lock does not exist' >&2
      return 1
    fi
    if [[ -n $new_temp ]]; then
      temporary=$new_temp
    else
      temporary=$(mktemp "$common_git_dir/.dotfiles-operation-bootstrap.XXXXXX") || {
        dotfiles_release_operation_lock
        return 1
      }
      new_temp=$temporary
      chmod 0600 "$temporary" || {
        rm -f -- "$temporary"
        sync "$common_git_dir" || true
        dotfiles_release_operation_lock
        return 1
      }
      if [[ $(stat -c '%u|%g' -- "$temporary") != "$expected_uid|$expected_gid" ]]; then
        chown "$expected_uid:$expected_gid" "$temporary" || {
          rm -f -- "$temporary"
          sync "$common_git_dir" || true
          dotfiles_release_operation_lock
          return 1
        }
      fi
    fi
    publication_status=0
    dotfiles_atomic_publish_no_replace "$temporary" "$lock_file" "$common_git_dir" || \
      publication_status=$?
    if [[ $publication_status -ne 0 && $publication_status -ne 2 ]]; then
      dotfiles_release_operation_lock
      return 1
    fi
  fi

  [[ -f $lock_file && ! -L $lock_file ]] || {
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: lock must be a regular file' >&2
    return 1
  }
  lock_path_metadata=$(stat -c '%d|%i|%u|%g|%a|%h|%s' -- "$lock_file") || {
    dotfiles_release_operation_lock
    return 1
  }
  IFS='|' read -r _device _inode lock_uid lock_gid lock_mode lock_links lock_size \
    <<< "$lock_path_metadata"
  [[ $lock_uid == "$expected_uid" && $lock_gid == "$expected_gid" &&
    $lock_mode == 600 && $lock_size == 0 ]] || {
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: lock has invalid owner, mode, or size' >&2
    return 1
  }
  if [[ -n $legacy_temp ]]; then
    [[ $lock_links == 2 &&
      $(stat -c '%d|%i' -- "$legacy_temp") == "$_device|$_inode" ]] || {
      dotfiles_release_operation_lock
      echo 'dotfiles-operation-lock: legacy residue does not identify the canonical lock' >&2
      return 1
    }
  elif [[ $lock_links != 1 ]]; then
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: lock has an invalid link count' >&2
    return 1
  fi

  exec {DOTFILES_OPERATION_LEGACY_LOCK_FD}< "$lock_file" || {
    dotfiles_release_operation_lock
    return 1
  }
  lock_fd_path=/proc/$BASHPID/fd/$DOTFILES_OPERATION_LEGACY_LOCK_FD
  lock_fd_metadata=$(stat -Lc '%d|%i|%u|%g|%a|%h|%s' -- "$lock_fd_path") || {
    dotfiles_release_operation_lock
    return 1
  }
  [[ $lock_path_metadata == "$lock_fd_metadata" ]] || {
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: lock changed while opening it' >&2
    return 1
  }
  flock --exclusive --nonblock "$DOTFILES_OPERATION_LEGACY_LOCK_FD" || {
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: another dotfiles state transition is running' >&2
    return 1
  }
  [[ $(stat -c '%d|%i|%u|%g|%a|%h|%s' -- "$lock_file") == "$lock_fd_metadata" ]] || {
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: lock changed after acquisition' >&2
    return 1
  }

  if [[ $bootstrap_mode == create && -n $legacy_temp ]]; then
    [[ $(stat -c '%d|%i|%u|%g|%a|%h|%s' -- "$legacy_temp") == "$lock_fd_metadata" ]] || {
      dotfiles_release_operation_lock
      return 1
    }
    rm -- "$legacy_temp" || {
      dotfiles_release_operation_lock
      return 1
    }
    sync "$common_git_dir" || {
      dotfiles_release_operation_lock
      return 1
    }
  elif [[ $bootstrap_mode == create && -n $new_temp && -e $new_temp ]]; then
    metadata=$(stat -c '%u|%g|%a|%h|%s' -- "$new_temp") || {
      dotfiles_release_operation_lock
      return 1
    }
    [[ $metadata == "$expected_uid|$expected_gid|600|1|0" ]] || {
      dotfiles_release_operation_lock
      return 1
    }
    rm -- "$new_temp" || {
      dotfiles_release_operation_lock
      return 1
    }
    sync "$common_git_dir" || {
      dotfiles_release_operation_lock
      return 1
    }
  fi
  metadata=$(stat -c '%d|%i|%u|%g|%a|%h|%s' -- "$lock_file") || {
    dotfiles_release_operation_lock
    return 1
  }
  [[ $metadata == "$_device|$_inode|$expected_uid|$expected_gid|600|1|0" ]] || {
    dotfiles_release_operation_lock
    echo 'dotfiles-operation-lock: lock identity is invalid after recovery' >&2
    return 1
  }
}
