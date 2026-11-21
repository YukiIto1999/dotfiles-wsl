spec=@spec@
program=dotfiles-tool-session

usage() {
  cat <<'EOF'
usage: dotfiles-tool-session list
       dotfiles-tool-session CLIENT CAPABILITY... -- [CLIENT-ARGUMENTS...]

Starts CLIENT once, in the current directory, with its normal MCP connector and
the named capabilities added for that process only. No client or profile
configuration is written. `list` prints each capability, its kind, and the
clients that can take it, and starts nothing.

A route is an endpoint of the shared gateway, and client arguments after --
are passed through unchanged. A private capability is a stdio server started
only for this invocation. At most one may be named, nothing may follow --, it
needs an interactive terminal on stdin and stdout, and it refuses to start from
inside an agent session. The client asks before each of its tool calls and
gives child agents no access to it. These checks keep a session from widening
by accident. They do not separate processes that run as the same user.

Exit status: 64 usage, 69 client without a session-scoped mechanism for the
capability, 77 refused private start; otherwise the client's own status.
EOF
  jq -r '.clients | to_entries[]
    | if .value.unsupported != null then "\nunsupported client \(.key): \(.value.unsupported)"
      elif .value.private.unsupported != null then "\nno private capabilities for \(.key): \(.value.private.unsupported)"
      else empty end' "$spec"
}

die() {
  local status=$1
  shift
  printf '%s: %s\n' "$program" "$*" >&2
  exit "$status"
}

case "${1-}" in
  list)
    [[ $# -eq 1 ]] || die 64 'list takes no arguments'
    jq -r '.clients as $clients | .capabilities | to_entries[]
      | .key as $name
      | [$name, .value.kind, ([$clients | to_entries[] | select(.value.launch[$name] != null) | .key] | join(","))]
      | @tsv' "$spec"
    exit 0
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  '')
    usage >&2
    exit 64
    ;;
esac

client=$1
shift
jq -e --arg client "$client" '.clients | has($client)' "$spec" >/dev/null \
  || die 64 "unknown client: $client"
reason=$(jq -r --arg client "$client" '.clients[$client].unsupported // empty' "$spec")
[[ -z $reason ]] || die 69 "$client cannot add an MCP server for one session: $reason"

capabilities=()
while [[ $# -gt 0 && $1 != -- ]]; do
  [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die 64 "unknown capability: $1"
  capabilities+=("$1")
  shift
done
[[ $# -gt 0 ]] || die 64 'separate the capabilities from the client arguments with --'
shift
[[ ${#capabilities[@]} -gt 0 ]] || die 64 'name at least one capability'

selection=$(jq -cn '$ARGS.positional' --args "${capabilities[@]}")
unknown=$(jq -r --argjson selection "$selection" '$selection - (.capabilities | keys) | join(", ")' "$spec")
[[ -z $unknown ]] || die 64 "unknown capability: $unknown"
repeated=$(jq -rn --argjson selection "$selection" \
  '$selection | group_by(.) | map(select(length > 1)[0]) | join(", ")')
[[ -z $repeated ]] || die 64 "capability named more than once: $repeated"

private=$(jq -r --argjson selection "$selection" \
  '. as $spec | [$selection[] | select($spec.capabilities[.].kind == "private")] | length' "$spec")
if [[ $private -gt 0 ]]; then
  reason=$(jq -r --arg client "$client" '.clients[$client].private.unsupported // empty' "$spec")
  [[ -z $reason ]] || die 69 "$client cannot take a private capability: $reason"
  [[ $private -eq 1 ]] || die 64 'name at most one private capability'
  [[ $# -eq 0 ]] || die 64 'a session with a private capability takes no client arguments'
  [[ -z ${DOTFILES_AGENT_SESSION_ID-} ]] \
    || die 77 "private capabilities start from the operator's terminal, not from inside agent session $DOTFILES_AGENT_SESSION_ID"
  [[ -t 0 && -t 1 ]] || die 77 'private capabilities need an interactive terminal on stdin and stdout'
fi

plan=$(jq -c --arg client "$client" --argjson selection "$selection" --argjson private "$(( private > 0 ))" '
  .clients[$client] as $entry
  | {
      executable: $entry.executable,
      environment: $entry.configEnvironment,
      args: ((if $private == 1 then $entry.private.args else [] end) + [$selection[] as $name | $entry.launch[$name].args[]]),
      config: (reduce ($selection[] as $name | $entry.launch[$name].config) as $part ({}; . * $part))
    }' "$spec")

environment=$(jq -r '.environment // empty' <<<"$plan")
config=$(jq -c '.config' <<<"$plan")
if [[ -n $environment ]]; then
  [[ -z ${!environment-} ]] || die 64 "$environment is already set; this command does not merge into it"
  export "$environment=$config"
elif [[ $config != '{}' ]]; then
  die 70 "internal error: $client has configuration but no variable to carry it"
fi

executable=$(jq -r '.executable' <<<"$plan")
mapfile -d '' -t launch_args < <(jq -j '.args[] | ., "\u0000"' <<<"$plan")
exec "$executable" "${launch_args[@]}" "$@"
