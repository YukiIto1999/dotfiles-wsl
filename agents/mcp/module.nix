{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.dotfiles;
  unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  mkNpmMcp = pkgs.callPackage ./mk-npm.nix { };
  inherit (pkgs) chromium;
  # project に依らない server は cwd を固定し、OMP が全 project の session で一つの process を共有できるようにする
  shared = {
    cwd = cfg.workstation.homeDir;
  };
  stdio = command: shared // { command = toString command; };

  # 起動の時点で sops の file から token を読む。token は mcp.json にも store にも載せない
  github =
    account:
    pkgs.writeShellScript "github-mcp-${account}" ''
      token_file=${lib.escapeShellArg config.sops.secrets."accounts/${account}/token".path}
      if [ ! -s "$token_file" ]; then
        echo "github-mcp-${account}: token file is empty or unreadable: $token_file" >&2
        exit 1
      fi
      GITHUB_PERSONAL_ACCESS_TOKEN=$(<"$token_file")
      export GITHUB_PERSONAL_ACCESS_TOKEN
      exec ${lib.getExe unstable.github-mcp-server} stdio \
        --toolsets context,issues,pull_requests,repos,users,actions "$@"
    '';

  # context 単位の userAgent 上書きが UA-CH の brand metadata を消すため native option は不採用
  playwrightConfig = pkgs.writeText "playwright-mcp-config.json" (
    builtins.toJSON {
      browser.launchOptions.args = [
        "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${lib.versions.major chromium.version}.0.0.0 Safari/537.36"
        "--disable-dev-shm-usage"
      ];
    }
  );
  playwright = pkgs.writeShellScript "playwright-mcp" ''
    session_dir=$(${lib.getExe' pkgs.coreutils "mktemp"} -d -- "''${XDG_RUNTIME_DIR:-/tmp}/playwright-mcp.XXXXXXXXXX")
    child_pid=
    cleanup() {
      rm -rf -- "$session_dir"
    }
    forward_signal() {
      if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        kill -s "$1" "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
      fi
      exit "$2"
    }
    trap cleanup EXIT
    trap 'forward_signal HUP 129' HUP
    # 非対話 shell 配下の子プロセスが無視する SIGINT
    trap 'forward_signal TERM 130' INT
    trap 'forward_signal TERM 143' TERM

    # session の出力は session の終了で消す
    ${pkgs.playwright-mcp}/bin/playwright-mcp \
      --browser chromium \
      --executable-path ${chromium}/bin/chromium \
      --headless \
      --isolated \
      --no-sandbox \
      --config ${playwrightConfig} \
      --output-dir "$session_dir" \
      "$@" <&0 &
    child_pid=$!
    status=0
    wait "$child_pid" || status=$?
    child_pid=
    exit "$status"
  '';

  chromeDevtoolsSource = inputs.chromeDevtoolsMcp;
  chromeDevtoolsPackage = mkNpmMcp {
    pname = "chrome-devtools-mcp";
    src = chromeDevtoolsSource;
    inherit ((builtins.fromJSON (builtins.readFile "${chromeDevtoolsSource}/package.json"))) version;
    lockFile = ./chrome-devtools/package-lock.json;
    npmDepsHash = "sha256-f2NTg/ijemxWlSpVranPCYQo11N4hcj1uW0KAt1ZCOw=";
  };
  # trace と screenshot の書き出し先。agent が後から読むため session をまたいで残す
  chromeDevtools = pkgs.writeShellScript "chrome-devtools-mcp" ''
    root="''${XDG_RUNTIME_DIR:-/tmp}/chrome-devtools-mcp"
    mkdir -p -m 0700 -- "$root"
    export TMPDIR="$root"
    exec ${chromeDevtoolsPackage}/bin/chrome-devtools-mcp --headless --isolated --no-usage-statistics \
      --no-performance-crux --executablePath ${chromium}/bin/chromium --filesystemRoot "$root" "$@"
  '';

  memlabVersion = "2.86.0";
  memlabPackage = mkNpmMcp {
    pname = "memlab-mcp";
    version = memlabVersion;
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@memlab/mcp-server/-/mcp-server-${memlabVersion}.tgz";
      hash = "sha256-orLjttxQwd1Dx7MhR1joDiwgaYj+ncBKjj+5EVvzdfc=";
    };
    lockFile = ./memlab/package-lock.json;
    npmDepsHash = "sha256-qT+aXu9gluo08xxceJgTlbXFPex8N6MBCwQz3HWrLp4=";
    extraPostPatch = ''
      cp ${./memlab/readonly-server.mjs} dist/readonly-server.js
      cp ${./memlab/admission.mjs} dist/admission.js
      cp ${./memlab/supervised-server.mjs} dist/supervised-server.js
    '';
  };
  memlab = pkgs.writeShellScript "memlab-mcp" ''
    export NODE_OPTIONS=--max-old-space-size=1024
    export MEMLAB_ANALYSIS_TIMEOUT_MS=45000
    exec ${lib.getExe pkgs.nodejs} ${memlabPackage}/lib/node_modules/@memlab/mcp-server/dist/supervised-server.js "$@"
  '';

  binlog = pkgs.callPackage ./binlog.nix { };
in
{
  dotfiles.agents.mcpServers = {
    playwright = stdio playwright;
    # 異なる観測契約を持つ trace・heap・Lighthouse の Playwright 統合禁止
    chrome-devtools = stdio chromeDevtools;
    context7 = stdio (lib.getExe unstable.context7-mcp);
    deepwiki = {
      type = "http";
      url = "https://mcp.deepwiki.com/mcp";
    };
    microsoft-learn = {
      type = "http";
      url = "https://learn.microsoft.com/api/mcp";
    };
    binlog = stdio (lib.getExe binlog);
    memlab = stdio memlab;
  }
  // lib.listToAttrs (
    map (
      account: lib.nameValuePair "github-${account}" (stdio (github account))
    ) cfg.identity.github.accounts
  );
}
