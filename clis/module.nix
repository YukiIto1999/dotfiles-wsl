{
  config,
  lib,
  pkgs,
  pluginSources,
  mkCommand,
  ...
}:

let
  orElse = v: default: if v == null then default else v;
  cfg = config.my;
  inherit (cfg) clis;
  names = builtins.attrNames clis;

  installType = lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.anything;
    options.kind = lib.mkOption {
      type = lib.types.enum [
        "installer-script"
        "github-release"
      ];
      description = "goal 05 の installer 生成が分岐に使う種別。";
    };
  };

  cliType = lib.types.submodule {
    options = {
      binary = lib.mkOption {
        type = lib.types.str;
        description = "~/.local/bin 配下の実行ファイル名。";
      };
      rulesFile = lib.mkOption {
        type = lib.types.str;
        description = "clis/assets/AGENTS.md の配備先。home 相対パス。";
      };
      skillsDir = lib.mkOption {
        type = lib.types.str;
        description = "skill 配備先ディレクトリ。home 相対パス。";
      };
      agentsDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "agent 配備先ディレクトリ。home 相対パス。null は agent 非対応。";
      };
      buildAgent = lib.mkOption {
        type = lib.types.nullOr lib.types.raw;
        default = null;
        description = "clis/assets/agents の md を CLI 固有形式へ変換する name: srcPath: drv 関数。";
      };
      gatewayFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "MCP gateway 設定ファイル。home 相対パス。doctor の検査対象。";
      };
      install = lib.mkOption {
        type = installType;
        description = "installer 生成が消費する CLI ごとの入手方法。";
      };
    };
  };

  # plugin skill は pluginSources 直下、local skill は dotfilesDir の live symlink を探索
  pluginPaths = [
    "${pluginSources.superpowers}"
    "${pluginSources.openai-plugins}/plugins/codex-security"
    "${pluginSources.claude-plugins-official}/plugins/frontend-design"
    "${pluginSources.claude-plugins-official}/plugins/skill-creator"
  ];

  findSkillsIn =
    pluginPath:
    let
      skillsRoot = "${pluginPath}/skills";
      entries = if builtins.pathExists skillsRoot then builtins.readDir skillsRoot else { };
      dirs = lib.filterAttrs (
        n: t: t == "directory" && builtins.pathExists "${skillsRoot}/${n}/SKILL.md"
      ) entries;
    in
    lib.mapAttrs' (name: _: lib.nameValuePair name "${skillsRoot}/${name}") dirs;

  pluginSkills = lib.foldl' (acc: p: acc // findSkillsIn p) { } pluginPaths;
  pluginSkillDupes =
    let
      flat = lib.concatMap (p: builtins.attrNames (findSkillsIn p)) pluginPaths;
      counts = lib.foldl' (acc: n: acc // { ${n} = (acc.${n} or 0) + 1; }) { } flat;
    in
    builtins.attrNames (lib.filterAttrs (_: c: c > 1) counts);

  localSkillsRoot = ./assets/skills;
  localSkills =
    lib.mapAttrs' (name: _: lib.nameValuePair name "${cfg.dotfilesDir}/clis/assets/skills/${name}")
      (
        lib.filterAttrs (
          n: t: t == "directory" && builtins.pathExists (localSkillsRoot + "/${n}/SKILL.md")
        ) (builtins.readDir localSkillsRoot)
      );

  localVsPluginDupes = builtins.filter (n: builtins.hasAttr n pluginSkills) (
    builtins.attrNames localSkills
  );

  allSkills = pluginSkills // localSkills;

  # clis/assets/agents/*.md の素材一覧
  agentSrcs =
    lib.mapAttrs'
      (
        filename: _: lib.nameValuePair (lib.removeSuffix ".md" filename) (./assets/agents + "/${filename}")
      )
      (
        lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (builtins.readDir ./assets/agents)
      );

  agentClis = lib.filter (name: clis.${name}.agentsDir != null) names;

  destBaseName = out: if lib.isDerivation out then out.name else builtins.baseNameOf (toString out);

  mkDupAssert = label: dupes: {
    assertion = dupes == [ ];
    message = "Duplicate skill names ${label}: " + lib.concatStringsSep ", " dupes;
  };
  installRow =
    name:
    let
      c = clis.${name};
    in
    if c.install.kind == "installer-script" then
      lib.concatStringsSep "|" [
        name
        c.install.kind
        c.binary
        c.install.scriptUrl
        ""
        ""
        ""
      ]
    else
      lib.concatStringsSep "|" [
        name
        c.install.kind
        c.binary
        c.install.repo
        c.install.assetByArch.x86_64
        c.install.assetByArch.aarch64
        (orElse (c.install.binaryInArchive or null) "")
      ];

  installClis = mkCommand {
    name = "dotfiles-install-clis";
    src = ./impl/install-clis.sh;
    vars.installTable = lib.concatStringsSep "\n" (map installRow names);
    runtimeInputs = with pkgs; [
      bash
      curl
      jq
      gnutar
      gzip
      coreutils
    ];
  };
in
{
  # CLI を 1 つ足すとは、clis/<name>/module.nix を作ること。収集は flake が行う
  options.my.clis = lib.mkOption {
    type = lib.types.attrsOf cliType;
    default = { };
    description = "AI CLI ごとの roster 宣言。1 CLI を足す単位は clis/<name>/。";
  };

  # per-CLI module が使う write-once seed installer、CLI が runtime 所有する設定を欠落 / stale symlink 時のみ書き込む
  config._module.args.seedConfig = rel: src: ''
    f="${cfg.homeDir}/${rel}"
    if [ -L "$f" ] || [ ! -e "$f" ]; then
      rm -f "$f"
      install -Dm600 ${src} "$f"
    fi
  '';

  config.my.doctor.skillNames = builtins.attrNames allSkills;
  config.my.doctor.agentFiles = lib.genAttrs agentClis (
    name:
    let
      def = clis.${name};
    in
    lib.mapAttrsToList (agentName: srcPath: destBaseName (def.buildAgent agentName srcPath)) agentSrcs
  );

  config.home-manager.users.${cfg.username} =
    { config, lib, ... }:
    {
      assertions = [
        (mkDupAssert "between local and plugins" localVsPluginDupes)
        (mkDupAssert "across plugins" pluginSkillDupes)
      ];

      home.file =
        (lib.listToAttrs (
          map (name: lib.nameValuePair clis.${name}.rulesFile { source = ./assets/AGENTS.md; }) names
        ))
        // (lib.listToAttrs (
          lib.concatMap (
            name:
            let
              dir = clis.${name}.skillsDir;
            in
            lib.mapAttrsToList (
              skillName: src:
              lib.nameValuePair "${dir}/${skillName}" {
                source =
                  if builtins.hasAttr skillName pluginSkills then src else config.lib.file.mkOutOfStoreSymlink src;
              }
            ) allSkills
          ) names
        ))
        // (lib.listToAttrs (
          lib.concatMap (
            name:
            let
              def = clis.${name};
            in
            lib.mapAttrsToList (
              agentName: srcPath:
              let
                out = def.buildAgent agentName srcPath;
              in
              lib.nameValuePair "${def.agentsDir}/${destBaseName out}" { source = out; }
            ) agentSrcs
          ) agentClis
        ));
    };

  config.my.commands.installClis = installClis;

  config.my.doctor.units."dotfiles-cli-autoupdate.timer".expected = {
    LoadState = "loaded";
    ActiveState = "active";
    SubState = "waiting";
    Result = "success";
  };

  config.systemd.services.dotfiles-cli-autoupdate = {
    description = "AI CLI を latest へ更新";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = cfg.username;
      Environment = [
        "HOME=${cfg.homeDir}"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
      ];
      ExecStart = lib.getExe installClis;
    };
  };

  config.systemd.timers.dotfiles-cli-autoupdate = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
