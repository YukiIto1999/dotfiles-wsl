{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        ...
      }:
      let
        toolchain = hostConfig.dotfiles.toolchain.packages;

        # 実 Dashboard の validateToken と同じく、今回の browser token だけに 200 を返す
        fakeServer = pkgs.writeText "fake-aspire-dashboard.py" ''
          import hmac, http.server, json, os

          TOKEN = os.environ["DASHBOARD__FRONTEND__BROWSERTOKEN"]

          class Handler(http.server.BaseHTTPRequestHandler):
              def do_POST(self):
                  body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                  token = json.loads(body).get("token", "")
                  ok = self.path == "/api/telemetry/validateToken" and hmac.compare_digest(token, TOKEN)
                  self.send_response(200 if ok else 401)
                  self.end_headers()
                  if ok:
                      self.wfile.write(b'{"apiKey":"generated-by-cli"}')

              def log_message(self, *args):
                  pass

          http.server.HTTPServer(("127.0.0.1", 18888), Handler).serve_forever()
        '';

        # 実 CLI の代わりに argv と環境を記録する。otel は response file を二度開く
        fakeAspire = pkgs.writeShellScriptBin "aspire" ''
          set -euo pipefail
          printf '%s\0' "$@" > "$FAKE_LOG/$1.$$.argv"
          case "$1 ''${2-}" in
            "dashboard run")
              pwd > "$FAKE_LOG/run.cwd"
              printf '%s\n' "$TMPDIR" > "$FAKE_LOG/run.tmpdir"
              env | ${pkgs.gnugrep}/bin/grep -E '^(DASHBOARD__[A-Z_]+MODE|ASPIRE_DASHBOARD_SUPPRESS_BROWSER_TOKEN_IN_OUTPUT)=' | sort > "$FAKE_LOG/run.env"
              exec ${lib.getExe pkgs.python3} ${fakeServer}
              ;;
            "otel logs" | "otel spans" | "otel traces")
              for arg in "$@"; do
                case $arg in
                  @*)
                    first=$(sha256sum < "''${arg#@}")
                    second=$(sha256sum < "''${arg#@}")
                    [ "$first" = "$second" ] || exit 65
                    printf '%s\n' "$first" > "$FAKE_LOG/otel.rsp.sha256"
                    ;;
                esac
              done
              echo otel-ok
              ;;
            *) exit 64 ;;
          esac
        '';
        dashboard = toolchain.aspire-dashboard.override { aspireCli = fakeAspire; };
      in
      {
        toolchain-aspire-dashboard-lifecycle =
          pkgs.runCommandLocal "check-toolchain-aspire-dashboard-lifecycle"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.findutils
                pkgs.gnugrep
                pkgs.gnused
              ];
            }
            ''
              set -euo pipefail
              export HOME=$PWD/home XDG_RUNTIME_DIR=$PWD/run TMPDIR=$PWD/tmp FAKE_LOG=$PWD/log
              mkdir -p "$HOME" "$TMPDIR" "$FAKE_LOG"
              mkdir -m 700 "$XDG_RUNTIME_DIR"
              dash=${lib.getExe dashboard}
              state=$XDG_RUNTIME_DIR/aspire-dashboard

              run() {
                local expected=$1 name=$2 status=0
                shift 2
                "$@" > "$name.out" 2> "$name.err" || status=$?
                if [ "$status" -ne "$expected" ]; then
                  echo "$name exited $status instead of $expected: $*" >&2
                  cat "$name.err" >&2
                  exit 1
                fi
              }
              fail() {
                echo "$1" >&2
                exit 1
              }
              environ() {
                tr '\0' '\n' < "/proc/$1/environ" | sed -n "s/^$2=//p"
              }

              run 2 no-arguments "$dash"
              run 0 help "$dash" --help
              run 2 invalid-browser-token "$dash" run --browser-token-stdin <<< invalid
              run 1 status-stopped "$dash" status
              run 1 otel-stopped "$dash" otel logs
              run 1 exec-stopped "$dash" exec -- true
              run 0 stop-stopped "$dash" stop

              "$dash" run > dashboard.out 2> dashboard.err &
              wrapper=$!
              for _ in $(seq 100); do
                "$dash" status > /dev/null 2>&1 && break
                sleep 0.1
              done
              run 0 status-ready "$dash" status
              run 1 second-run "$dash" run
              grep -Fq 'already running' second-run.err || fail 'second run did not report the running instance'

              [ "$(stat -c %a "$state")" = 700 ] || fail 'runtime state is not private'
              [ "$(cat "$FAKE_LOG/run.cwd")" = "$state" ] || fail 'dashboard did not run from the private state directory'
              read -r pid run_id < "$state/run"
              [ "$(environ "$pid" ASPIRE_DASHBOARD_RUN_ID)" = "$run_id" ] || fail 'run record does not match the dashboard process'
              browser_token=$(environ "$pid" DASHBOARD__FRONTEND__BROWSERTOKEN)
              otlp_key=$(environ "$pid" DASHBOARD__OTLP__PRIMARYAPIKEY)
              for secret in "$browser_token" "$otlp_key"; do
                [ ''${#secret} -eq 64 ] || fail 'generated credential is not 256 bits of hex'
              done
              grep -Fxq DASHBOARD__FRONTEND__AUTHMODE=BrowserToken "$FAKE_LOG/run.env" || fail 'browser token auth not selected'
              grep -Fxq DASHBOARD__OTLP__AUTHMODE=ApiKey "$FAKE_LOG/run.env" || fail 'OTLP key auth not selected'
              grep -Fxq ASPIRE_DASHBOARD_SUPPRESS_BROWSER_TOKEN_IN_OUTPUT=true "$FAKE_LOG/run.env" || fail 'browser token output is not suppressed'
              case $(cat "$FAKE_LOG/run.tmpdir") in
                "$TMPDIR"/aspire-dashboard.*) ;;
                *) fail 'dashboard data is outside the per-run directory' ;;
              esac
              tr '\0' '\n' < "$FAKE_LOG"/dashboard.*.argv > run-argv.txt
              grep -Fxq None run-argv.txt || fail 'temporary persistence missing'
              grep -Fxq -- '--Logging:LogLevel:Microsoft.AspNetCore=Warning' run-argv.txt || fail 'request log filter missing'
              grep -Fxq -- '--Dashboard:TelemetryLimits:MaxLogCount=10000' run-argv.txt || fail 'log limit missing'

              run 0 otel "$dash" otel traces --format Json
              grep -Fxq otel-ok otel.out || fail 'otel reader was not called'
              expected=$(printf '%s\n' --dashboard-url "http://127.0.0.1:18888/login?t=$browser_token" | sha256sum)
              [ "$(cat "$FAKE_LOG/otel.rsp.sha256")" = "$expected" ] || fail 'otel reader did not receive the login URL twice'
              tr '\0' '\n' < "$FAKE_LOG"/otel.*.argv > otel-argv.txt
              grep -Fxq -- '--format' otel-argv.txt || fail 'otel options were not forwarded'
              [ -z "$(find "$state" -name 'otel.*')" ] || fail 'otel response file was written to disk'

              "$dash" exec --service checked-service -- bash -c \
                'printf "%s\n" "$OTEL_EXPORTER_OTLP_ENDPOINT" "$OTEL_EXPORTER_OTLP_PROTOCOL" "$OTEL_EXPORTER_OTLP_HEADERS" "$OTEL_SERVICE_NAME" "$OTEL_RESOURCE_ATTRIBUTES"' \
                > exec-env.txt
              [ "$(sed -n 1p exec-env.txt)" = http://127.0.0.1:18890 ] || fail 'exec endpoint mismatch'
              [ "$(sed -n 2p exec-env.txt)" = http/protobuf ] || fail 'exec protocol mismatch'
              [ "$(sed -n 3p exec-env.txt)" = "x-otlp-api-key=$otlp_key" ] || fail 'exec OTLP header mismatch'
              [ "$(sed -n 4p exec-env.txt)" = checked-service ] || fail 'exec service name mismatch'
              sed -n 5p exec-env.txt | grep -Eq '(^|,)service\.namespace=[^,]+(,|$)' || fail 'exec namespace missing'
              sed -n 5p exec-env.txt | grep -Eq '(^|,)service\.instance\.id=[0-9a-f]{16}(,|$)' || fail 'exec instance id missing'
              OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:4318 OTEL_RESOURCE_ATTRIBUTES=service.instance.id=fixed \
                "$dash" exec -- bash -c 'printf "%s\n" "''${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT-unset}" "$OTEL_RESOURCE_ATTRIBUTES"' > exec-override.txt
              [ "$(sed -n 1p exec-override.txt)" = unset ] || fail 'signal-specific endpoint was not removed'
              sed -n 2p exec-override.txt | grep -Eq '^service\.instance\.id=fixed,service\.namespace=[^,]+$' || fail 'explicit instance id was not kept'

              # 生成した資格情報は file、argv、端末出力に出さない
              for secret in "$browser_token" "$otlp_key"; do
                for file in "$FAKE_LOG"/* ./*.out ./*.err ./*-argv.txt; do
                  if grep -Fq -- "$secret" "$file"; then
                    fail "credential leaked into $file"
                  fi
                done
                if grep -rFq -D skip -- "$secret" "$XDG_RUNTIME_DIR" "$TMPDIR"; then
                  fail 'credential was written to the runtime or data directory'
                fi
              done

              run 0 stop "$dash" stop
              status=0
              wait "$wrapper" || status=$?
              [ "$status" -eq 0 ] || fail "run exited $status after stop"
              [ ! -e "$state" ] || fail 'runtime state remained after stop'
              [ -z "$(ls -A "$TMPDIR")" ] || fail 'per-run data remained after stop'
              run 1 status-after-stop "$dash" status

              mkdir -m 700 -- "$state"
              abandoned=$(mktemp -d "$TMPDIR/aspire-dashboard.XXXXXXXX")
              unrelated=$(mktemp -d "$TMPDIR/other.XXXXXXXX")
              printf '%s\n' "$abandoned" > "$state/data-dir"
              run 0 reclaim-stopped "$dash" stop
              [ ! -e "$state" ] && [ ! -e "$abandoned" ] && [ -d "$unrelated" ] \
                || fail 'stop did not reclaim exactly the abandoned run'

              touch "$out"
            '';
      }
    )
  ];
}
