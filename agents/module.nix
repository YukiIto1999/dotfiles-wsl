{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.dotfiles;
  ws = cfg.workstation;
  llmAgents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  systemd = config.systemd.package;

  # 本文は checkout から link し、編集を rebuild なしで反映する
  checkoutPath = relative: "${ws.dotfilesDir}/agents/${relative}";
  standardClone = "${ws.homeDir}/.local/share/dotfiles-agent/architecture-standard";
  wrapperDirectory = ".local/share/dotfiles-agent/bin";

  localSkills = lib.mapAttrs (name: _: checkoutPath "skills/${name}") (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./skills)
  );
  upstreamSkills = import ./skills.nix { inherit inputs; };
  # 標準は固定せず、dotfiles-standard-sync が更新する clone を指す。clone が無い間の link は宙に浮くだけで害はない
  standardSkills = lib.genAttrs [
    "standard-apply"
    "standard-audit"
    "standard-conformance"
    "standard-feedback"
    "standard-update"
    "property-testing"
  ] (name: "${standardClone}/skills/${name}");
  checkoutSkills = localSkills // standardSkills;
  duplicateSkills = lib.intersectLists (builtins.attrNames upstreamSkills) (
    builtins.attrNames checkoutSkills
  );

  profileRoot = "${ws.homeDir}/.local/state/nix/profiles";

  # OMP の managed browser が起動する Chromium。指定が無いと OMP は Chrome for Testing を取得するが、
  # NixOS では共有 library が無く起動しない。下の omp の起動より前から動く session と共有 daemon は
  # LD_LIBRARY_PATH を持ったままで、Chromium の起動を壊すため外す（2026-11-26 の実測）
  ompBrowser = pkgs.writeShellScript "omp-chromium" ''
    unset LD_LIBRARY_PATH
    exec ${lib.getExe pkgs.chromium} "$@"
  '';

  clients = {
    omp = {
      binary = "omp";
      package = "omp";
      # package の bin/omp は本体の native library のために LD_LIBRARY_PATH を足し、agent が起動する command、
      # MCP server、browser にも漏らした。別の glibc で build された pulseaudio などを読み込み、Chromium や qemu が
      # `GLIBC_2.43 not found` で止まった事例が 2026-10-27〜11-26 に 7 project の 21 session であったため、
      # 本体を直接起動する。本体が必要とする library は RUNPATH で解決され、足していた pulseaudio と pipewire は
      # 音声出力（say）と Wayland の画面取得が dlopen するだけで、その二つは使えなくなる（直近30日の say の利用は0回）
      unwrapped = "lib/omp/omp";
      environment = {
        # 版の更新は dotfiles-agent-update が行う
        PI_SKIP_VERSION_CHECK = "1";
        PUPPETEER_EXECUTABLE_PATH = "${ompBrowser}";
      };
    };
    claude = {
      binary = "claude";
      package = "claude-code";
    };
    codex = {
      binary = "codex";
      package = "codex";
    };
    opencode = {
      binary = "opencode";
      package = "opencode";
    };
    antigravity = {
      binary = "agy";
      package = "antigravity-cli";
    };
  };

  # 日次の更新が検証済みの世代を置く profile を優先し、無ければ flake の固定版を使う。
  # unwrapped を持つ client は、package の wrapper の代わりに本体を起動する（本体が無い版では wrapper へ戻る）
  clientExecutable =
    name: client:
    pkgs.writeShellScript "dotfiles-${name}" (
      ''
        profile_binary=${lib.escapeShellArg "${profileRoot}/${name}/bin/${client.binary}"}
        if [ -x "$profile_binary" ]; then
          binary=$profile_binary
        else
          binary=${lib.getExe' llmAgents.${client.package} client.binary}
        fi
      ''
      + lib.optionalString (client ? unwrapped) ''
        package=$(${lib.getExe' pkgs.coreutils "readlink"} -f -- "$binary")
        package=''${package%/bin/${client.binary}}
        if [ -x "$package/${client.unwrapped}" ]; then
          # package の wrapper が設定していた値。版の更新は dotfiles-agent-update が行う
          export PI_SKIP_VERSION_CHECK=1
          exec "$package/${client.unwrapped}" "$@"
        fi
      ''
      + ''
        exec "$binary" "$@"
      ''
    );

  # client の process tree を memory の会計と上限のためだけに agents.slice の scope へ置く。
  # user manager に届かないときも起動は拒まない
  wrapper =
    name: client:
    pkgs.writeShellApplication {
      name = client.binary;
      text = ''
        # MSBuild の node と build server は session の終了後も数時間残ったため再利用させない
        export MSBUILDDISABLENODEREUSE=1
        export DOTNET_CLI_USE_MSBUILD_SERVER=0
        ${lib.concatStrings (
          lib.mapAttrsToList (key: value: "export ${key}=${lib.escapeShellArg value}\n") (
            client.environment or { }
          )
        )}
        if ${systemd}/bin/systemctl --user show --property=Version >/dev/null 2>&1; then
          exec ${systemd}/bin/systemd-run --user --scope --quiet --collect --slice=agents.slice \
            --unit="${name}-$$-$RANDOM.scope" -- ${clientExecutable name client} "$@"
        fi
        echo "${client.binary}: systemd user manager is unreachable; starting outside agents.slice" >&2
        exec ${clientExecutable name client} "$@"
      '';
    };

  hookDirectory = pkgs.runCommandLocal "omp-hooks-pre" { } (
    ''
      mkdir "$out"
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: source: ''
        cp ${source} "$out"/${lib.escapeShellArg name}
      '') cfg.agents.omp.hooks
    )
  );

  mcpConfig = (pkgs.formats.json { }).generate "omp-mcp.json" {
    # server が配る instructions は全 session と subagent の prompt へ入り、Skill を入口にする経路と別の初手を指示するため載せない
    mcpServers = lib.mapAttrs (_: server: { instructions = false; } // server) cfg.agents.mcpServers;
  };

  standardSync = pkgs.writeShellApplication {
    name = "dotfiles-standard-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
    ];
    text = ''
      clone=${lib.escapeShellArg standardClone}
      if [ ! -d "$clone/.git" ]; then
        mkdir -p -- "$(dirname -- "$clone")"
        git clone --quiet https://github.com/YukiIto1999/architecture-standard "$clone"
        exit 0
      fi
      # 既定 branch を fast-forward だけで追う。手元の変更や分岐があれば止めて知らせる
      git -C "$clone" fetch --quiet origin
      git -C "$clone" remote set-head origin --auto >/dev/null
      git -C "$clone" merge --ff-only --quiet "$(git -C "$clone" symbolic-ref --short refs/remotes/origin/HEAD)"
    '';
  };

  brief = pkgs.writeShellApplication {
    name = "dotfiles-agent-brief";
    runtimeInputs = [ pkgs.git ];
    text = ''
      exec ${lib.getExe pkgs.python3} ${./brief/work-brief.py} "$@"
    '';
  };

  dailyTimer = description: {
    Unit.Description = description;
    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # 日次で各 client を最新へ更新し、起動できない世代は戻す。一つの失敗で他の client の更新を止めない
  agentUpdate = pkgs.writeShellApplication {
    name = "dotfiles-agent-update";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      config.nix.package
    ];
    text = ''
      profile_root=${lib.escapeShellArg profileRoot}
      mkdir -p -- "$profile_root"
      update() {
        local name=$1 package=$2 binary=$3
        local profile="$profile_root/$name" existed=0
        if [ -e "$profile" ]; then
          existed=1
          nix profile upgrade --profile "$profile" --all || return 1
        else
          nix profile install --profile "$profile" "github:numtide/llm-agents.nix#$package" || return 1
        fi
        if ! "$profile/bin/$binary" --version; then
          echo "dotfiles-agent-update: the new $name generation does not start; reverting" >&2
          if [ "$existed" = 1 ]; then
            nix profile rollback --profile "$profile"
          else
            rm -f -- "$profile"
          fi
          return 1
        fi
        nix profile wipe-history --profile "$profile" --older-than 14d
      }
      status=0
      ${lib.concatStrings (
        lib.mapAttrsToList (name: client: ''
          update ${
            lib.escapeShellArgs [
              name
              client.package
              client.binary
            ]
          } || status=1
        '') clients
      )}
      exit "$status"
    '';
  };
in
{
  imports = [
    ./mcp/module.nix
    ./omp/module.nix
    ./transition.nix
  ];

  options.dotfiles.agents = {
    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = "OMP の mcp.json の mcpServers。名前から OMP の server 定義（stdio の command と args と env と cwd、または type http と url）への対応。";
    };
    omp.hooks = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = "~/.omp/agent/hooks/pre に置く hook。file 名から source への対応。";
    };
    ompExecutable = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "scope を作らずに OMP を起動する実行ファイル。agents.slice の中で既に動く job が使う。";
    };
  };

  config = {
    dotfiles.agents.ompExecutable = clientExecutable "omp" clients.omp;

    assertions = [
      {
        assertion = duplicateSkills == [ ];
        message = "Skill IDs must be unique across local, upstream and standard Skills: ${lib.concatStringsSep ", " duplicateSkills}";
      }
    ];

    home-manager.users.${ws.username} =
      { config, ... }:
      let
        link = config.lib.file.mkOutOfStoreSymlink;
        policy = link (checkoutPath "AGENTS.md");
        skillFiles =
          root:
          lib.mapAttrs' (
            name: path: lib.nameValuePair "${root}/${name}" { source = link path; }
          ) checkoutSkills
          // lib.mapAttrs' (
            name: path: lib.nameValuePair "${root}/${name}" { source = path; }
          ) upstreamSkills;
      in
      {
        home.packages = [
          brief
          standardSync
        ];
        # client の native installer や古い供給の残りが ~/.local/bin に同名の command を置くため、
        # wrapper はそれより前の専用 directory から引く（2026-11-26 の切替で ~/.local/bin/omp が旧版の 18.10.4 を起動した）
        home.sessionPath = lib.mkBefore [ "$HOME/${wrapperDirectory}" ];

        home.file = {
          ".omp/agent/AGENTS.md".source = policy;
          # omp の task subagent は AGENTS.md を継承せず、RULES.md だけを読む
          ".omp/agent/RULES.md".source = link (checkoutPath "RULES.md");
          ".omp/agent/agents/implementer.md".source = link (checkoutPath "subagents/implementer.md");
          ".omp/agent/mcp.json".source = mcpConfig;
          # omp は hook directory の中の symlink を読み込まない。Home Manager は file ごとに symlink を張るため、
          # directory ごと配備し、その中を実 file にする
          ".omp/agent/hooks/pre".source = hookDirectory;
          ".claude/CLAUDE.md".source = policy;
          ".codex/AGENTS.md".source = policy;
          ".config/opencode/AGENTS.md".source = policy;
          ".gemini/GEMINI.md".source = policy;
          ".local/share/dotfiles-agent/references/modern-web-guidance".source = inputs.modernWebGuidance;
          ${wrapperDirectory}.source =
            pkgs.symlinkJoin {
              name = "dotfiles-agent-wrappers";
              paths = lib.mapAttrsToList wrapper clients;
            }
            + "/bin";
        }
        // skillFiles ".omp/agent/skills"
        // skillFiles ".claude/skills"
        // skillFiles ".codex/skills"
        // skillFiles ".config/opencode/skills"
        # Antigravity の App と CLI が共通に読む個人の skill directory
        // skillFiles ".gemini/config/skills";

        systemd.user.services.dotfiles-standard-sync = {
          Unit.Description = "architecture-standard の clone を既定 branch へ fast-forward";
          Service = {
            Type = "oneshot";
            Environment = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" ];
            ExecStart = lib.getExe standardSync;
          };
        };
        systemd.user.timers.dotfiles-standard-sync = dailyTimer "architecture-standard の日次同期";

        systemd.user.services.dotfiles-agent-update = {
          Unit.Description = "agent client を最新へ更新";
          Service = {
            Type = "oneshot";
            Environment = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" ];
            ExecStart = lib.getExe agentUpdate;
          };
        };
        systemd.user.timers.dotfiles-agent-update = {
          Unit.Description = "agent client の日次更新";
          Timer = {
            OnCalendar = "daily";
            # 配備直後は profile の無い client が flake の固定版で起動するため、timer の開始から間を置かずに最新を入れる
            OnActiveSec = "1min";
            Persistent = true;
          };
          Install.WantedBy = [ "timers.target" ];
        };
      };
  };
}
