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

  ompExecutable = pkgs.writeShellScript "dotfiles-omp" ''
    # 日次の更新が検証済みの世代を置く profile を優先し、無ければ flake の固定版を使う
    profile_omp=${lib.escapeShellArg "${ws.homeDir}/.local/state/nix/profiles/omp/bin/omp"}
    if [ -x "$profile_omp" ]; then
      exec "$profile_omp" "$@"
    fi
    exec ${lib.getExe' llmAgents.omp "omp"} "$@"
  '';

  clients = {
    omp = {
      binary = "omp";
      executable = ompExecutable;
      # 版の更新は dotfiles-omp-update が行う
      environment.PI_SKIP_VERSION_CHECK = "1";
    };
    claude = {
      binary = "claude";
      executable = lib.getExe' llmAgents.claude-code "claude";
    };
    codex = {
      binary = "codex";
      executable = lib.getExe' llmAgents.codex "codex";
    };
    opencode = {
      binary = "opencode";
      executable = lib.getExe' llmAgents.opencode "opencode";
    };
    antigravity = {
      binary = "agy";
      executable = lib.getExe' llmAgents.antigravity-cli "agy";
    };
  };

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
            --unit="${name}-$$-$RANDOM.scope" -- ${client.executable} "$@"
        fi
        echo "${client.binary}: systemd user manager is unreachable; starting outside agents.slice" >&2
        exec ${client.executable} "$@"
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
    dotfiles.agents.ompExecutable = ompExecutable;

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
        home.packages = lib.mapAttrsToList wrapper clients ++ [
          brief
          standardSync
        ];

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
        }
        // skillFiles ".omp/agent/skills"
        // skillFiles ".claude/skills"
        // skillFiles ".codex/skills"
        // skillFiles ".config/opencode/skills";

        systemd.user.services.dotfiles-standard-sync = {
          Unit.Description = "architecture-standard の clone を既定 branch へ fast-forward";
          Service = {
            Type = "oneshot";
            Environment = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" ];
            ExecStart = lib.getExe standardSync;
          };
        };
        systemd.user.timers.dotfiles-standard-sync = dailyTimer "architecture-standard の日次同期";
      };
  };
}
