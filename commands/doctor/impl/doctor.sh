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
targets=@mcpTargets@
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

# gateway が答えても、target が fanout で落ちていれば tool は使えない。
# 宣言した target 名が tools/list に現れることまで見る
session=$(curl -sS -m 10 -D- -o /dev/null \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dotfiles-doctor","version":"1"}}}' \
  "$gateway" 2>/dev/null | grep -i '^mcp-session-id:' | cut -d' ' -f2 | tr -d '\r')

if [ -n "$session" ]; then
  tools=$(curl -sS -m 30 \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -H "mcp-session-id: $session" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    "$gateway" 2>/dev/null | grep -oE '"name":"[a-z0-9_-]+' | sed 's/"name":"//')
  for target in $targets; do
    printf '%s\n' "$tools" | grep -q "^${target}_" || failed+=("target=$target")
  done
fi

if ((json)); then
  printf '{"gateway":"%s","failed":[' "$gateway_state"
  printf '"%s"' "${failed[0]-}"
  for f in "${failed[@]:1}"; do printf ',"%s"' "$f"; done
  printf ']}\n'
elif ((${#failed[@]} == 0)); then
  printf 'gateway: %s\nunits: all active\n' "$gateway_state"
else
  printf 'gateway: %s\nunits not active:\n' "$gateway_state"
  printf '  %s\n' "${failed[@]}"
fi

if ((${#failed[@]} > 0)); then
  exit 1
fi
exit 0