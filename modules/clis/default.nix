{
  config,
  lib,
  pluginSources,
  ...
}:

# my.clis roster と share/ fan-out engine。CLI を 1 つ足す単位はこのディレクトリ配下。
let
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
        description = "share/AGENTS.md の配備先。home 相対パス。";
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
        description = "share/agents の md を CLI 固有形式へ変換する name: srcPath: drv 関数。";
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

  # plugin skill(pluginSources 直下)と local skill(dotfilesDir の live symlink)を探索
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

  localSkillsRoot = ../../share/skills;
  localSkills =
    lib.mapAttrs' (name: _: lib.nameValuePair name "${cfg.dotfilesDir}/share/skills/${name}")
      (
        lib.filterAttrs (
          n: t: t == "directory" && builtins.pathExists (localSkillsRoot + "/${n}/SKILL.md")
        ) (builtins.readDir localSkillsRoot)
      );

  localVsPluginDupes = builtins.filter (n: builtins.hasAttr n pluginSkills) (
    builtins.attrNames localSkills
  );

  allSkills = pluginSkills // localSkills;

  # share/agents/*.md の素材一覧、名前は拡張子抜き
  agentSrcs =
    lib.mapAttrs'
      (
        filename: _:
        lib.nameValuePair (lib.removeSuffix ".md" filename) (../../share/agents + "/${filename}")
      )
      (
        lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (
          builtins.readDir ../../share/agents
        )
      );

  agentClis = lib.filter (name: clis.${name}.agentsDir != null) names;

  # 変換結果の配備ファイル名。derivation は自身の name、素通しは srcPath の basename を使う
  destBaseName = out: if lib.isDerivation out then out.name else builtins.baseNameOf (toString out);

  mkDupAssert = label: dupes: {
    assertion = dupes == [ ];
    message = "Duplicate skill names ${label}: " + lib.concatStringsSep ", " dupes;
  };
in
{
  # CLI を 1 つ足すとは、ここへ 1 行足すこと
  imports = [
    ./claude
    ./codex
    ./opencode
    ./antigravity
  ];

  options.my.clis = lib.mkOption {
    type = lib.types.attrsOf cliType;
    default = { };
    description = "AI CLI ごとの roster 宣言。1 CLI を足す単位は modules/clis/<name>/。";
  };

  # per-CLI module が使う write-once seed installer。CLI が runtime 所有する設定を欠落 / stale symlink 時のみ書き込む
  config._module.args.seedConfig = rel: src: ''
    f="${cfg.homeDir}/${rel}"
    if [ -L "$f" ] || [ ! -e "$f" ]; then
      rm -f "$f"
      install -Dm600 ${src} "$f"
    fi
  '';

  config.home-manager.users.${cfg.username} =
    { config, lib, ... }:
    {
      assertions = [
        (mkDupAssert "between local and plugins" localVsPluginDupes)
        (mkDupAssert "across plugins" pluginSkillDupes)
      ];

      home.file =
        (lib.listToAttrs (
          map (name: lib.nameValuePair clis.${name}.rulesFile { source = ../../share/AGENTS.md; }) names
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
}
