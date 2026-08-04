# systemd が unit の状態を持ち、MCP は endpoint が答えるかでしか確かめられない。
# その二つだけを見る。宣言との照合は nix flake check が行う
usage() {
  cat <<'USAGE'
usage: dotfiles-doctor [--json]

Report the state of the units this configuration declares and whether the MCP
gateway answers. Exit 0 when everything is healthy, 1 otherwise.
USAGE
}

json=0
case "${1-}" in
  --json) json=1 ;;
  --help | -h) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

units=@declaredUnits@
gateway=@gatewayUrl@

failed=()
for unit in $units; do
  state=$(systemctl show "$unit" --property=ActiveState --value 2>/dev/null || echo unknown)
  [[ $state == active ]] || failed+=("$unit=$state")
done

# MCP は initialize が返って初めて使える。unit が active でも session が張れない
gateway_state=ok
if ! curl -sS -m 10 -o /dev/null \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dotfiles-doctor","version":"1"}}}' \
  "$gateway"; then
  gateway_state=unreachable
  failed+=("gateway=$gateway_state")
fi

if ((json)); then
  printf '{"gateway":"%s","failed":[' "$gateway_state"
  printf '"%s"' "${failed[0]-}"
  for f in "${failed[@]:1}"; do printf ',"%s"' "$f"; done
  printf ']}\n'
else
  printf 'gateway: %s\n' "$gateway_state"
  if ((${#failed[@]} == 0)); then
    printf 'units: all active\n'
  else
    printf 'units not active:\n'
    printf '  %s\n' "${failed[@]}"
  fi
fi

((${#failed[@]} == 0))
