{
  pkgs,
  playwrightMcp ? pkgs.playwright-mcp,
  chromium ? pkgs.chromium,
}:

# browser.userAgent が Chromium の起動オプションへ反映されない playwright-mcp の制約
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
in
pkgs.writeShellApplication {
  name = "playwright-mcp-front";
  runtimeInputs = [ pkgs.coreutils ];
  excludeShellChecks = [ "SC2329" ];
  text = ''
    : "''${RUNTIME_DIRECTORY:?systemd runtime directory is not set}"
    session_dir=$(mktemp -d -- "$RUNTIME_DIRECTORY/playwright.XXXXXXXXXX")
    chmod 0700 "$session_dir"
    child_pid=

    cleanup() {
      rm -rf -- "$session_dir"
    }
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
    # 非対話 shell 配下の子プロセスが無視する SIGINT
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
}
