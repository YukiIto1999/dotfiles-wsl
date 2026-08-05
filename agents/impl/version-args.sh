decode_version_args() {
  local json=$1

  # NUL は argv framing 専用。Nix string は null byte を表現できず、manifest 構築前に拒否される。
  jq --join-output '.[] | ., "\u0000"' <<< "$json"
}

run_version_check() {
  local binary=$1 version_args_json=$2
  local -a version_args

  mapfile -d '' -t version_args < <(decode_version_args "$version_args_json")
  "$binary" "${version_args[@]}"
}
