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
