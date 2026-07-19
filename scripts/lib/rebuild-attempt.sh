dotfiles_rebuild_validate_attempt_directory() {
  local directory=$1 expected_uid=$2 expected_gid=$3 metadata

  [[ -d $directory && ! -L $directory ]] || {
    echo "dotfiles-rebuild-attempt: path must be a real directory: $directory" >&2
    return 1
  }
  metadata=$(stat -c '%u|%g|%a' -- "$directory")
  [[ $metadata == "$expected_uid|$expected_gid|700" ]] || {
    echo "dotfiles-rebuild-attempt: directory has invalid owner or mode: $directory" >&2
    return 1
  }
}

dotfiles_rebuild_prepare_attempt_directory() {
  local state_root=$1 expected_uid=$2 expected_gid=$3 transaction_id=$4 ordinal=$5 attempt_id=$6
  local attempts_root transaction_root attempt_root parent

  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ $ordinal =~ ^[1-9][0-9]*$ ]] || return 1
  [[ $attempt_id =~ ^[0-9a-f]{32}$ ]] || return 1
  attempts_root=$state_root/attempts
  transaction_root=$attempts_root/$transaction_id
  attempt_root=$transaction_root/$ordinal-$attempt_id

  for directory in "$attempts_root" "$transaction_root" "$attempt_root"; do
    if [[ ! -e $directory && ! -L $directory ]]; then
      parent=${directory%/*}
      mkdir -m 0700 -- "$directory" || return 1
      sync "$parent" || return 1
    fi
    dotfiles_rebuild_validate_attempt_directory \
      "$directory" "$expected_uid" "$expected_gid" || return 1
  done
  printf '%s\n' "$attempt_root"
}

dotfiles_rebuild_validate_attempt_file() {
  local file=$1 expected_uid=$2 expected_mode=$3 metadata

  [[ -f $file && ! -L $file ]] || {
    echo "dotfiles-rebuild-attempt: artifact must be a regular file: $file" >&2
    return 1
  }
  metadata=$(stat -c '%u|%a|%h' -- "$file")
  [[ $metadata == "$expected_uid|$expected_mode|1" ]] || {
    echo "dotfiles-rebuild-attempt: artifact has invalid owner, mode, or link count: $file" >&2
    return 1
  }
}

dotfiles_rebuild_create_attempt_json() {
  local attempt_root=$1 expected_uid=$2 expected_gid=$3 name=$4 target temporary

  [[ $name =~ ^(intent|started|outcome)\.json$ ]] || return 1
  dotfiles_rebuild_validate_attempt_directory \
    "$attempt_root" "$expected_uid" "$expected_gid" || return 1
  target=$attempt_root/$name
  [[ ! -e $target && ! -L $target ]] || return 1
  temporary=$(mktemp "$attempt_root/.$name.XXXXXX") || return 1
  chmod 0600 "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  if ! jq -e . > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  dotfiles_rebuild_validate_attempt_file "$temporary" "$expected_uid" 600 || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  mv -T --no-copy --update=none-fail -- "$temporary" "$target" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$target" || return 1
  sync "$attempt_root" || return 1
}

dotfiles_rebuild_prepare_partial_log() {
  local attempt_root=$1 expected_uid=$2 expected_gid=$3 partial_log
  partial_log=$attempt_root/activation.log.partial

  dotfiles_rebuild_validate_attempt_directory \
    "$attempt_root" "$expected_uid" "$expected_gid" || return 1
  [[ ! -e $partial_log && ! -L $partial_log ]] || return 1
  if ! (umask 077; set -o noclobber; : > "$partial_log"); then
    return 1
  fi
  chmod 0600 "$partial_log" || return 1
  dotfiles_rebuild_validate_attempt_file "$partial_log" "$expected_uid" 600 || return 1
  sync --data "$partial_log" || return 1
  sync "$attempt_root" || return 1
}

dotfiles_rebuild_finalize_attempt_log() {
  local attempt_root=$1 expected_uid=$2 expected_gid=$3 partial_log final_log partial_mode
  partial_log=$attempt_root/activation.log.partial
  final_log=$attempt_root/activation.log

  dotfiles_rebuild_validate_attempt_directory \
    "$attempt_root" "$expected_uid" "$expected_gid" || return 1
  partial_mode=$(stat -c '%a' -- "$partial_log" 2>/dev/null) || return 1
  [[ $partial_mode == 600 || $partial_mode == 400 ]] || return 1
  dotfiles_rebuild_validate_attempt_file \
    "$partial_log" "$expected_uid" "$partial_mode" || return 1
  [[ ! -e $final_log && ! -L $final_log ]] || return 1
  sync --data "$partial_log" || return 1
  if [[ $partial_mode == 600 ]]; then
    chmod 0400 "$partial_log" || return 1
  fi
  mv -T --no-copy --update=none-fail -- "$partial_log" "$final_log" || return 1
  sync --data "$final_log" || return 1
  sync "$attempt_root" || return 1
  dotfiles_rebuild_validate_attempt_file "$final_log" "$expected_uid" 400
}

dotfiles_rebuild_attempt_artifact_metadata() {
  local state_root=$1 file=$2 expected_uid=$3 expected_mode=$4 relative sha bytes

  dotfiles_rebuild_validate_attempt_file "$file" "$expected_uid" "$expected_mode" || return 1
  [[ $file == "$state_root/"* ]] || return 1
  relative=${file#"$state_root/"}
  sha=$(sha256sum "$file" | cut -d ' ' -f 1) || return 1
  bytes=$(stat -c '%s' -- "$file") || return 1
  [[ $sha =~ ^[0-9a-f]{64}$ && $bytes =~ ^[0-9]+$ ]] || return 1
  jq -cn \
    --arg path "$relative" \
    --arg sha256 "$sha" \
    --argjson bytes "$bytes" \
    '{path: $path, sha256: $sha256, bytes: $bytes}'
}

dotfiles_rebuild_verify_artifact_metadata() {
  local state_root=$1 metadata=$2 expected_uid=$3 expected_mode=$4 expected_path=$5
  local path file expected_sha expected_bytes actual_sha actual_bytes

  path=$(jq -er '.path | select(type == "string")' <<< "$metadata") || return 1
  expected_sha=$(jq -er '.sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' \
    <<< "$metadata") || return 1
  expected_bytes=$(jq -er '.bytes | select(type == "number" and . >= 0 and floor == .)' \
    <<< "$metadata") || return 1
  [[ $path == "$expected_path" ]] || return 1
  file=$state_root/$path
  dotfiles_rebuild_validate_attempt_file "$file" "$expected_uid" "$expected_mode" || return 1
  actual_sha=$(sha256sum "$file" | cut -d ' ' -f 1) || return 1
  actual_bytes=$(stat -c '%s' -- "$file") || return 1
  [[ $actual_sha == "$expected_sha" && $actual_bytes == "$expected_bytes" ]]
}

dotfiles_rebuild_verify_receipt_artifacts() {
  local state_root=$1 receipt=$2 expected_uid=$3 expected_gid=$4
  local transaction_id attempt number attempt_id attempt_root prefix metadata artifact_file
  local direction target action baseline boot_baseline driver_protocol driver_executable store_prefix
  local intent_json started_json outcome_json
  local migrations_root migration_root

  [[ $(jq -r '.schemaVersion' <<< "$receipt") -eq 3 ]] || return 0
  transaction_id=$(jq -r '.transactionId' <<< "$receipt")

  while IFS= read -r attempt; do
    [[ -n $attempt ]] || continue
    number=$(jq -r '.number' <<< "$attempt")
    attempt_id=$(jq -r '.attemptId' <<< "$attempt")
    prefix=attempts/$transaction_id/$number-$attempt_id
    attempt_root=$state_root/$prefix
    direction=$(jq -r '.direction' <<< "$attempt")
    target=$(jq -r '.target' <<< "$attempt")
    action=$(jq -r '.action' <<< "$attempt")
    store_prefix=${target%/*}/
    driver_protocol=$(jq -r '.activationDriver.protocol' <<< "$receipt")
    driver_executable=$(jq -r '.activationDriver.executable' <<< "$receipt")
    baseline=$(jq -c '.activationBaseline' <<< "$attempt")
    boot_baseline=$(jq -c '.bootBaseline' <<< "$attempt")
    dotfiles_rebuild_validate_attempt_directory \
      "$state_root/attempts" "$expected_uid" "$expected_gid" || return 1
    dotfiles_rebuild_validate_attempt_directory \
      "$state_root/attempts/$transaction_id" "$expected_uid" "$expected_gid" || return 1
    dotfiles_rebuild_validate_attempt_directory \
      "$attempt_root" "$expected_uid" "$expected_gid" || return 1

    metadata=$(jq -c '.intent' <<< "$attempt")
    dotfiles_rebuild_verify_artifact_metadata \
      "$state_root" "$metadata" "$expected_uid" 600 "$prefix/intent.json" || return 1
    artifact_file=$attempt_root/intent.json
    intent_json=$(cat -- "$artifact_file") || return 1
    jq -e \
      --arg transactionId "$transaction_id" \
      --argjson number "$number" \
      --arg attemptId "$attempt_id" \
      --arg direction "$direction" \
      --arg target "$target" \
      --arg action "$action" \
      --arg driverProtocol "$driver_protocol" \
      --arg driverExecutable "$driver_executable" \
      --argjson activationBaseline "$baseline" \
      --argjson bootBaseline "$boot_baseline" \
      --arg createdAt "$(jq -r '.createdAt' <<< "$attempt")" '
        .schemaVersion == 1 and .transactionId == $transactionId and
        .number == $number and .attemptId == $attemptId and
        .direction == $direction and .target == $target and .action == $action and
        .driver == {protocol: $driverProtocol, executable: $driverExecutable} and
        .activationBaseline == $activationBaseline and .bootBaseline == $bootBaseline and
        .createdAt == $createdAt
      ' <<< "$intent_json" > /dev/null || {
      echo "dotfiles-rebuild-attempt: intent projection mismatch: $artifact_file" >&2
      return 1
    }
    if [[ $(jq -r '.started != null' <<< "$attempt") == true ]]; then
      metadata=$(jq -c '.started' <<< "$attempt")
      dotfiles_rebuild_verify_artifact_metadata \
        "$state_root" "$metadata" "$expected_uid" 600 "$prefix/started.json" || return 1
      artifact_file=$attempt_root/started.json
      started_json=$(cat -- "$artifact_file") || return 1
      jq -e \
        --arg transactionId "$transaction_id" \
        --argjson number "$number" \
        --arg attemptId "$attempt_id" \
        --arg startedAt "$(jq -r '.startedAt' <<< "$attempt")" '
          .schemaVersion == 1 and .transactionId == $transactionId and
          .number == $number and .attemptId == $attemptId and
          (.runnerPid | type == "string" and test("^[1-9][0-9]*$")) and
          .startedAt == $startedAt
        ' <<< "$started_json" > /dev/null || {
        echo "dotfiles-rebuild-attempt: started projection mismatch: $artifact_file" >&2
        return 1
      }
    fi
    if [[ $(jq -r '.log != null' <<< "$attempt") == true ]]; then
      metadata=$(jq -c '.log' <<< "$attempt")
      dotfiles_rebuild_verify_artifact_metadata \
        "$state_root" "$metadata" "$expected_uid" 400 "$prefix/activation.log" || return 1
    fi
    if [[ $(jq -r '.outcome != null' <<< "$attempt") == true ]]; then
      metadata=$(jq -c '.outcome' <<< "$attempt")
      dotfiles_rebuild_verify_artifact_metadata \
        "$state_root" "$metadata" "$expected_uid" 600 "$prefix/outcome.json" || return 1
      artifact_file=$attempt_root/outcome.json
      outcome_json=$(cat -- "$artifact_file") || return 1
      jq -e \
        --arg transactionId "$transaction_id" \
        --argjson number "$number" \
        --arg attemptId "$attempt_id" \
        --arg status "$(jq -r '.status' <<< "$attempt")" \
        --arg store "$store_prefix" \
        --arg action "$action" \
        --arg target "$target" \
        --arg boundary "$(jq -r '.boundary' <<< "$attempt")" \
        --arg finishedAt "$(jq -r '.finishedAt' <<< "$attempt")" \
        --argjson activationBaseline "$baseline" \
        --argjson bootBaseline "$boot_baseline" \
        --argjson exitCode "$(jq -c '.exitCode' <<< "$attempt")" \
        --argjson captureExitCode "$(jq -c '.log.captureExitCode' <<< "$attempt")" \
        --argjson truncated "$(jq -c '.log.truncated' <<< "$attempt")" '
          .schemaVersion == 1 and .transactionId == $transactionId and
          .number == $number and .attemptId == $attemptId and
          .exitCode == $exitCode and .captureExitCode == $captureExitCode and
          .truncated == $truncated and .boundary == $boundary and
          .finishedAt == $finishedAt and
          ([.observedRuntime.current, .observedRuntime.booted, .observedRuntime.profile] |
            all(type == "string" and startswith($store))) and
          (.observedBootInstance.kernelBootId | type == "string" and
            test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
          (.observedBootInstance.userspaceTimestampMonotonic | type == "string" and
            test("^[1-9][0-9]*$")) and
          (if $status == "indeterminate" then
            .reconciled == true
          else
            (has("reconciled") | not) and
            .observedBootInstance == $bootBaseline and
            (if $action == "switch" then
              .observedRuntime.booted == $activationBaseline.booted and
              (.observedRuntime.current == $activationBaseline.current or
                .observedRuntime.current == $target) and
              (.observedRuntime.profile == $activationBaseline.profile or
                .observedRuntime.profile == $target)
            else
              .observedRuntime.current == $activationBaseline.current and
              .observedRuntime.booted == $activationBaseline.booted and
              (.observedRuntime.profile == $activationBaseline.profile or
                .observedRuntime.profile == $target)
            end) and
            (if $exitCode == 0 then
              $boundary == "after-profile-commit" and
              (if $action == "switch" then
                .observedRuntime.current == $target and
                .observedRuntime.profile == $target
              else
                .observedRuntime.current == $activationBaseline.current and
                .observedRuntime.profile == $target
              end)
            elif (.observedRuntime == $activationBaseline and
              $activationBaseline.profile != $target) then
              $boundary == "before-profile-commit"
            elif .observedRuntime.profile == $target then
              $boundary == "after-profile-commit"
            else
              $boundary == "unknown"
            end)
          end)
        ' <<< "$outcome_json" > /dev/null || {
        echo "dotfiles-rebuild-attempt: outcome projection mismatch: $artifact_file" >&2
        return 1
      }
    fi
  done < <(jq -c '.activation.attempts[], .rollback.activation.attempts[]?' <<< "$receipt")

  if [[ $(jq -r '.migration != null' <<< "$receipt") == true ]]; then
    migrations_root=$state_root/migrations
    migration_root=$migrations_root/$transaction_id
    dotfiles_rebuild_validate_attempt_directory \
      "$migrations_root" "$expected_uid" "$expected_gid" || return 1
    dotfiles_rebuild_validate_attempt_directory \
      "$migration_root" "$expected_uid" "$expected_gid" || return 1
    metadata=$(jq -c '.migration.receipt' <<< "$receipt")
    dotfiles_rebuild_verify_artifact_metadata \
      "$state_root" "$metadata" "$expected_uid" 400 \
      "migrations/$transaction_id/schema-2.json" || return 1
  fi
}

dotfiles_rebuild_preserve_schema2_receipt() {
  local state_root=$1 expected_uid=$2 expected_gid=$3 transaction_id=$4 source_receipt=$5
  local migrations_root transaction_root target temporary parent

  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
  dotfiles_rebuild_validate_attempt_file "$source_receipt" "$expected_uid" 600 || return 1
  migrations_root=$state_root/migrations
  transaction_root=$migrations_root/$transaction_id
  for directory in "$migrations_root" "$transaction_root"; do
    if [[ ! -e $directory && ! -L $directory ]]; then
      parent=${directory%/*}
      mkdir -m 0700 -- "$directory" || return 1
      sync "$parent" || return 1
    fi
    dotfiles_rebuild_validate_attempt_directory \
      "$directory" "$expected_uid" "$expected_gid" || return 1
  done
  target=$transaction_root/schema-2.json
  if [[ -e $target || -L $target ]]; then
    dotfiles_rebuild_validate_attempt_file "$target" "$expected_uid" 400 || return 1
    cmp -s -- "$source_receipt" "$target" || return 1
    printf '%s\n' "$target"
    return 0
  fi
  temporary=$(mktemp "$transaction_root/.schema-2.XXXXXX") || return 1
  chmod 0600 "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  cp -- "$source_receipt" "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  chmod 0400 "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  dotfiles_rebuild_validate_attempt_file "$temporary" "$expected_uid" 400 || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  mv -T --no-copy --update=none-fail -- "$temporary" "$target" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$target" || return 1
  sync "$transaction_root" || return 1
  sync "$migrations_root" || return 1
  printf '%s\n' "$target"
}
