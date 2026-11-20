{
  configuration = [
    (
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
        target = hostConfig.dotfiles.platform.mcp.targets.zvec-grep;
        front = hostConfig.dotfiles.platform.mcp.fronts.zvec-grep;
        service = hostConfig.systemd.services.${front.service};
        endpoint = "http://127.0.0.1:${toString port}/mcp";
        homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.workstation.username};
        staleLockPath = "${hostConfig.dotfiles.workstation.homeDir}/.zvec-grep/daemon/instance.lock";
        staleLockRule = hostConfig.systemd.tmpfiles.settings."zvec-grep".${staleLockPath}."r!";
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
          assert homeConfig.home.sessionVariables.ZVEC_GREP_MODEL_CACHE == "${frontPackage.modelCache}";
          assert staleLockRule.type == "r!";
          pkgs.runCommandLocal "check-zvec-grep-front"
            {
              nativeBuildInputs = with pkgs; [
                coreutils
                curl
                gawk
                gnugrep
                gnused
                jq
                systemd
              ];
            }
            ''
              set -euo pipefail

              grep -Fq ${lib.escapeShellArg endpoint} ${hostConfig.dotfiles.platform.mcp.gateway.source}

              test_root=$TMPDIR/tmpfiles-root
              mkdir -p "$test_root$(dirname ${lib.escapeShellArg staleLockPath})"
              printf '{"pid":1}\n' > "$test_root${staleLockPath}"
              printf '%s %s - - - - -\n' ${lib.escapeShellArg staleLockRule.type} ${lib.escapeShellArg staleLockPath} > zvec-grep.conf
              systemd-tmpfiles --remove --root="$test_root" - < zvec-grep.conf
              test -e "$test_root${staleLockPath}"
              systemd-tmpfiles --remove --boot --root="$test_root" - < zvec-grep.conf
              test ! -e "$test_root${staleLockPath}"

              export HOME=$TMPDIR/home
              export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
              export ZVEC_GREP_HOME="$HOME/.zvec-grep"
              export ZVEC_GREP_MODEL_CACHE=${lib.escapeShellArg homeConfig.home.sessionVariables.ZVEC_GREP_MODEL_CACHE}
              instance="$ZVEC_GREP_HOME/daemon/instance.lock"
              mkdir -p "$(dirname "$instance")"
              printf '{"pid":1}\n' > "$instance"
              ${lib.getExe frontPackage} >server.log 2>&1 &
              server_pid=$!
              stop_fixture() {
                kill "$server_pid" 2>/dev/null || return
                if ! timeout 5 tail --pid="$server_pid" -f /dev/null; then
                  kill -KILL "$server_pid" 2>/dev/null || true
                fi
                wait "$server_pid"
              }
              trap 'stop_fixture || true' EXIT

              ready=false
              for _ in $(seq 1 100); do
                if curl --silent --fail --output /dev/null --max-time 1 \
                  http://127.0.0.1:${toString port}/healthz; then
                  ready=true
                  break
                fi
                sleep 0.1
              done
              if [ "$ready" != true ]; then
                cat server.log >&2
                exit 1
              fi
              jq -e --argjson pid "$server_pid" '
                .pid == $pid and .daemonProtocolVersion == 2 and .ready and .mcpToolset == "agent"
              ' "$instance" >/dev/null
              cp "$instance" instance.running.json
              if ${lib.getExe frontPackage} >duplicate.log 2>&1; then
                echo 'A second daemon replaced the running instance' >&2
                exit 1
              fi
              grep -Fq 'already running' duplicate.log
              cmp instance.running.json "$instance"

              rpc_response() {
                local stem=$1 id=$2
                if grep -qi '^content-type: application/json' "$stem.headers"; then
                  jq -c --argjson id "$id" 'select(.id == $id)' "$stem.body"
                else
                  sed -n 's/^data: //p' "$stem.body" | jq -c --argjson id "$id" 'select(.id == $id)'
                fi > "$stem.json"
                jq -e --argjson id "$id" '.id == $id and .error == null' "$stem.json" >/dev/null
              }

              jq -cn '{
                jsonrpc:"2.0",
                id:1,
                method:"initialize",
                params:{
                  protocolVersion:"2025-11-25",
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
              rpc_response initialize 1
              jq -e '
                .result.protocolVersion == "2025-11-25" and .result.serverInfo.version == "0.3.1"
              ' initialize.json >/dev/null

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
                --header 'MCP-Protocol-Version: 2025-11-25' \
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
                --header 'MCP-Protocol-Version: 2025-11-25' \
                --data-binary @tools.request \
                ${lib.escapeShellArg endpoint}

              rpc_response tools 2
              jq -e '
                ([.result.tools[].name] | sort) ==
                  ["zvec_grep_callees", "zvec_grep_callers", "zvec_grep_search"] and
                (.result.tools[] | select(.name == "zvec_grep_search") | .inputSchema |
                  .required == ["root"] and
                  .additionalProperties == false and
                  .properties.limit.type == "integer" and
                  .properties.autoUpdate.type == "boolean") and
                all(.result.tools[] | select(.name != "zvec_grep_search");
                  .inputSchema.additionalProperties == false and
                  (.inputSchema.required | sort) == ["root", "symbol"] and
                  .inputSchema.properties.limit.type == "integer")
              ' tools.json >/dev/null

              workspace=$TMPDIR/workspace
              mkdir -p "$workspace"
              printf '%s\n' 'export function parseDuration(text) { return Number.parseInt(text, 10) * 1000; }' > "$workspace/duration.js"
              printf '%s\n' 'def render_markdown_table(rows): return "|".join(rows)' > "$workspace/table.py"
              if ! timeout 30 ${lib.getExe zvecGrep} --index "$workspace" --mode server \
                --embedding local/potion-code-16m-v2 --device cpu --embedding-concurrency 2 >index.log 2>&1; then
                tr '\r' '\n' <index.log | tail -n 5 >&2
                cat server.log >&2
                exit 1
              fi
              (
                cd "$workspace"
                ${lib.getExe zvecGrep} --mode direct --refresh off --color never \
                  --vector 'convert a time string to milliseconds' --limit 1
              ) > direct-query.out
              grep -Fq 'duration.js' direct-query.out

              jq -cn --arg root "$workspace" '{
                jsonrpc:"2.0",id:3,method:"tools/call",
                params:{name:"zvec_grep_search",arguments:{
                  root:$root,vector:["convert a time string to milliseconds"],limit:1,autoUpdate:false
                }}
              }' >search.request
              curl --silent --show-error --fail-with-body --max-time 30 \
                --request POST \
                --dump-header search.headers \
                --output search.body \
                --header 'content-type: application/json' \
                --header 'accept: application/json, text/event-stream' \
                --header "mcp-session-id: $session_id" \
                --header 'MCP-Protocol-Version: 2025-11-25' \
                --data-binary @search.request \
                ${lib.escapeShellArg endpoint}
              rpc_response search 3
              jq -e '
                .result.isError != true and
                any(.result.content[]; .type == "text" and (.text | contains("duration.js")))
              ' search.json >/dev/null

              jq '
                .id = 4 |
                .params._meta = {
                  "io.modelcontextprotocol/protocolVersion":"2026-07-28",
                  "io.modelcontextprotocol/clientCapabilities":{},
                  "io.modelcontextprotocol/clientInfo":{name:"zvec-grep-nix-check",version:"1"}
                }
              ' search.request >stateless.request
              curl --silent --show-error --fail-with-body --max-time 30 \
                --request POST \
                --dump-header stateless.headers \
                --output stateless.body \
                --header 'content-type: application/json' \
                --header 'accept: application/json, text/event-stream' \
                --header 'MCP-Protocol-Version: 2026-07-28' \
                --header 'Mcp-Method: tools/call' \
                --header 'Mcp-Name: zvec_grep_search' \
                --data-binary @stateless.request \
                ${lib.escapeShellArg endpoint}
              ! grep -qi '^mcp-session-id:' stateless.headers
              rpc_response stateless 4
              jq -e '
                .result.isError != true and
                any(.result.content[]; .type == "text" and (.text | contains("duration.js")))
              ' stateless.json >/dev/null

              stop_fixture
              test ! -e "$instance"
              trap - EXIT
              touch $out
            '';
      }
    )
  ];
}
