# Frozen pre-migration behavior used to prove old/new generation interoperability.
dotfiles_acquire_operation_lock() {
  local common_git_dir=$1 expected_uid=$2 expected_gid=$3 lock_file lock_metadata temporary

  [[ $common_git_dir == /* && -d $common_git_dir && ! -L $common_git_dir ]] || return 1
  [[ $(stat -c '%u' -- "$common_git_dir") == "$expected_uid" ]] || return 1

  lock_file=$common_git_dir/dotfiles-operation.lock
  if [[ ! -e $lock_file && ! -L $lock_file ]]; then
    temporary=$(mktemp "$common_git_dir/.dotfiles-operation.XXXXXX") || return 1
    chmod 0600 "$temporary"
    if [[ $(stat -c '%u|%g' -- "$temporary") != "$expected_uid|$expected_gid" ]]; then
      chown "$expected_uid:$expected_gid" "$temporary"
    fi
    ln -- "$temporary" "$lock_file" 2>/dev/null || true
    rm -f -- "$temporary"
  fi

  [[ -f $lock_file && ! -L $lock_file ]] || return 1
  lock_metadata=$(stat -c '%u|%g|%a|%h' -- "$lock_file")
  [[ $lock_metadata == "$expected_uid|$expected_gid|600|1" ]] || return 1
  exec {DOTFILES_OPERATION_LOCK_FD}< "$lock_file"
  flock -n "$DOTFILES_OPERATION_LOCK_FD"
}
