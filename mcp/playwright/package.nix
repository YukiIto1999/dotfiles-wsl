{
  pkgs,
  mkMcpServer,
  playwrightMcp ? pkgs.playwright-mcp,
  chromium ? pkgs.chromium,
}:

# host chromium を headless 起動する純 stdio server
# bot 判定を避ける Windows UA、chromium launch args で付与、browser.userAgent は無視される
let
  userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";
  config = pkgs.writeText "playwright-mcp-config.json" (
    builtins.toJSON {
      browser.launchOptions.args = [
        "--user-agent=${userAgent}"
        "--disable-dev-shm-usage"
      ];
    }
  );
  sessionRunner = pkgs.writeShellApplication {
    name = "playwright-mcp-session";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      : "''${PLAYWRIGHT_MCP_RUNTIME_DIR:?agentgateway runtime directory is not set}"
      session_dir=$(mktemp -d -- "$PLAYWRIGHT_MCP_RUNTIME_DIR/playwright.XXXXXXXXXX")
      chmod 0700 "$session_dir"
      child_pid=

      # shellcheck disable=SC2329 # EXIT trap から呼ぶ
      cleanup() {
        rm -rf -- "$session_dir"
      }
      # shellcheck disable=SC2329 # signal trap から呼ぶ
      forward_signal() {
        local signal=$1
        local status=$2
        if [[ -n $child_pid ]] && kill -0 "$child_pid" 2>/dev/null; then
          kill -s "$signal" "$child_pid" 2>/dev/null || true
          wait "$child_pid" 2>/dev/null || true
        fi
        exit "$status"
      }
      trap cleanup EXIT
      trap 'forward_signal HUP 129' HUP
      # 非対話 shell の background child は SIGINT を無視するため TERM へ変換する
      trap 'forward_signal TERM 130' INT
      trap 'forward_signal TERM 143' TERM

      ${playwrightMcp}/bin/playwright-mcp \
        --browser chromium \
        --executable-path ${chromium}/bin/chromium \
        --headless \
        --isolated \
        --no-sandbox \
        --config ${config} \
        --output-dir "$session_dir" \
        "$@" <&0 &
      child_pid=$!

      status=0
      wait "$child_pid" || status=$?
      child_pid=
      exit "$status"
    '';
  };
in
mkMcpServer {
  name = "playwright-mcp";
  command = "${sessionRunner}/bin/playwright-mcp-session";
}
