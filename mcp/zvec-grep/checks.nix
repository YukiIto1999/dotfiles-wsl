{
  hostConfig,
  lib,
  pkgs,
  ...
}:

let
  port = 8784;
  zvecGrep = hostConfig.dotfiles.toolchain.packages.zvec-grep;
  frontPackage = pkgs.callPackage ./package.nix {
    inherit port zvecGrep;
  };
  target = hostConfig.dotfiles.mcp.targets.zvec-grep;
  front = hostConfig.dotfiles.mcp.fronts.zvec-grep;
  service = hostConfig.systemd.services.${front.service};
  endpoint = "http://127.0.0.1:${toString port}/mcp";
  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.host.username};
in
{
  zvec-grep-front =
    assert target.provider == "zvec-grep";
    assert target.executable == lib.getExe frontPackage;
    assert target.serverTransport == "streamable-http";
    assert target.serverLifecycle == "service";
    assert target.port == port;
    assert target.needsNetwork == false;
    assert target.waitUnits == [ ];
    assert front.url == endpoint;
    assert service.serviceConfig.ExecStart == lib.getExe frontPackage;
    assert homeConfig.home.sessionVariables.ZVEC_GREP_MODE == "auto";
    assert homeConfig.home.sessionVariables.ZVEC_GREP_SERVER_URL == endpoint;
    pkgs.runCommandLocal "check-zvec-grep-front"
      {
        nativeBuildInputs = with pkgs; [
          coreutils
          curl
          gawk
          gnugrep
          gnused
          jq
        ];
      }
      ''
        set -euo pipefail

        grep -Fq ${lib.escapeShellArg endpoint} ${hostConfig.dotfiles.mcp.gateway.source}

        export HOME=$TMPDIR/home
        mkdir -p "$HOME"
        ${lib.getExe frontPackage} >server.log 2>&1 &
        server_pid=$!
        trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT

        ready=false
        for _ in $(seq 1 100); do
          if curl --silent --output /dev/null --max-time 1 ${lib.escapeShellArg endpoint}; then
            ready=true
            break
          fi
          sleep 0.1
        done
        if [ "$ready" != true ]; then
          cat server.log >&2
          exit 1
        fi

        jq -cn '{
          jsonrpc:"2.0",
          id:1,
          method:"initialize",
          params:{
            protocolVersion:"2025-06-18",
            capabilities:{},
            clientInfo:{name:"zvec-grep-nix-check",version:"1"}
          }
        }' >initialize.request
        curl --silent --show-error --fail-with-body --max-time 5 \
          --request POST \
          --dump-header initialize.headers \
          --output initialize.body \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --data-binary @initialize.request \
          ${lib.escapeShellArg endpoint}

        session_id=$(awk '
          tolower($1) == "mcp-session-id:" {gsub("\\r", "", $2); print $2}
        ' initialize.headers)
        test -n "$session_id"

        jq -cn '{jsonrpc:"2.0",method:"notifications/initialized",params:{}}' >initialized.request
        test "$(curl --silent --show-error --fail-with-body --max-time 5 \
          --request POST \
          --output initialized.body \
          --write-out '%{http_code}' \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header "mcp-session-id: $session_id" \
          --header 'MCP-Protocol-Version: 2025-06-18' \
          --data-binary @initialized.request \
          ${lib.escapeShellArg endpoint})" = 202

        jq -cn '{jsonrpc:"2.0",id:2,method:"tools/list",params:{}}' >tools.request
        curl --silent --show-error --fail-with-body --max-time 5 \
          --request POST \
          --dump-header tools.headers \
          --output tools.body \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header "mcp-session-id: $session_id" \
          --header 'MCP-Protocol-Version: 2025-06-18' \
          --data-binary @tools.request \
          ${lib.escapeShellArg endpoint}

        if grep -qi '^content-type: application/json' tools.headers; then
          cp tools.body tools.json
        else
          sed -n 's/^data: //p' tools.body | jq -c 'select(.id == 2)' >tools.json
        fi
        jq -e '[.result.tools[].name] == ["zvec_grep_search"]' tools.json >/dev/null

        kill "$server_pid"
        wait "$server_pid" || true
        trap - EXIT
        touch $out
      '';
}
