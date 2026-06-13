{ pkgs, lib, osConfig, pluginSources, dotfilesAbs, symlink, ... }:

let
  inherit (osConfig) my;
  inherit (my) gatewayUrl;

  skills    = import ./skills.nix { inherit lib pluginSources dotfilesAbs; localSkillsRoot = ../share/skills; };
  allSkills = skills.all;

  # agent frontmatter の分割
  splitFrontmatter = src:
    let parts = lib.splitString "\n---\n" (builtins.readFile src);
    in {
      frontmatter = lib.removePrefix "---\n" (builtins.head parts);
      body        = lib.concatStringsSep "\n---\n" (builtins.tail parts);
    };
  # 生成 codex agent TOML に焼き込むモデル
  codexModel = "gpt-5.5";

  # agentDir 未定義の CLI は static agent を配備しない
  cliDefs = {
    claude = {
      skillDir   = ".claude/skills";
      agentDir   = ".claude/agents";
      agentExt   = "md";
      buildAgent = _: srcPath: srcPath;
    };
    codex = {
      skillDir   = ".codex/skills";
      agentDir   = ".codex/agents";
      agentExt   = "toml";
      buildAgent = name: srcPath:
        let fm = splitFrontmatter srcPath; in
        pkgs.runCommand "${name}.toml" {
          nativeBuildInputs = [ pkgs.remarshal pkgs.yq ];
          inherit (fm) frontmatter body;
        } ''
          yq -y 'del(.tools)' <<<"$frontmatter" | remarshal -if yaml -of toml > "$out"
          {
            printf 'model = "${codexModel}"\n'
            printf 'developer_instructions = """\n'
            printf '%s\n' "$body"
            printf '"""\n'
          } >> "$out"
        '';
    };
    opencode = {
      skillDir   = ".config/opencode/skills";
      agentDir   = ".config/opencode/agents";
      agentExt   = "md";
      buildAgent = name: srcPath:
        let fm = splitFrontmatter srcPath; in
        pkgs.runCommand "${name}.md" {
          nativeBuildInputs = [ pkgs.yq ];
          inherit (fm) frontmatter body;
        } ''
          tools=$(yq -y '.tools |= (map({(ascii_downcase):true}) | add)' <<<"$frontmatter")
          {
            printf '%s\n' '---'
            printf '%s\n' "$tools"
            printf '%s\n' '---'
            printf '%s\n' "$body"
          } > "$out"
        '';
    };
    antigravity = {
      skillDir = ".gemini/antigravity-cli/skills";
    };
  };

  skillFiles = lib.listToAttrs (lib.concatMap (cli:
      let def = cliDefs.${cli}; in
      lib.mapAttrsToList (name: src: {
        name  = "${def.skillDir}/${name}";
        value = { source = symlink src; };
      }) allSkills
    ) (builtins.attrNames cliDefs));

  agents = lib.mapAttrs' (filename: _:
      let baseName = lib.removeSuffix ".md" filename;
      in lib.nameValuePair baseName (../share/agents + "/${filename}")
    ) (lib.filterAttrs (n: t:
         t == "regular" && (lib.hasSuffix ".md" n)
       ) (builtins.readDir ../share/agents));

  agentClis  = lib.filter (cli: cliDefs.${cli} ? agentDir) (builtins.attrNames cliDefs);
  agentFiles = lib.listToAttrs (lib.concatMap (cli:
      let def = cliDefs.${cli}; in
      lib.mapAttrsToList (name: srcPath: {
        name  = "${def.agentDir}/${name}.${def.agentExt}";
        value = { source = def.buildAgent name srcPath; };
      }) agents
    ) agentClis);

  # 共有 rule と CLI ごとの gateway 登録
  ruleFiles = {
    ".claude/CLAUDE.md".source          = ../share/AGENTS.md;
    ".codex/AGENTS.md".source           = ../share/AGENTS.md;
    ".config/opencode/AGENTS.md".source = ../share/AGENTS.md;
    ".gemini/AGENTS.md".source          = ../share/AGENTS.md;
    ".config/opencode/opencode.json".source =
      pkgs.replaceVars ./nixos/.config/opencode/opencode.json { inherit gatewayUrl; };
    ".gemini/antigravity-cli/mcp_config.json".source =
      pkgs.replaceVars ./nixos/.gemini/antigravity-cli/mcp_config.json { inherit gatewayUrl; };
  };

  mkDupAssert = label: dupes: {
    assertion = dupes == [ ];
    message   = "Duplicate skill names ${label}: " + lib.concatStringsSep ", " dupes;
  };

  # CLI が runtime 所有する seed config、欠落か stale symlink 時のみ書き込み
  seedConfig = rel: src: ''
    f="${my.homeDir}/${rel}"
    if [ -L "$f" ] || [ ! -e "$f" ]; then
      rm -f "$f"
      install -Dm600 ${src} "$f"
    fi
  '';
in
{
  assertions = [
    (mkDupAssert "between local and plugins" skills.localVsPluginDupes)
    (mkDupAssert "across plugins" skills.pluginSkillDupes)
  ];

  home.file = ruleFiles // skillFiles // agentFiles;

  home.activation.seedMutableConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    seedConfig ".claude/settings.json" ./nixos/.claude/settings.json
    + seedConfig ".codex/config.toml" ./nixos/.codex/config.toml
  );

  # claude は ~/.claude.json を runtime 所有するため gateway を imperative 登録
  # claude バイナリ欠落でも後続 activation を止めない if ガード
  home.activation.claudeMcpRegister = lib.hm.dag.entryAfter [ "seedMutableConfigs" ] ''
    CLAUDE=$HOME/.local/bin/claude
    if [ -x "$CLAUDE" ]; then
      $CLAUDE mcp remove gateway --scope user >/dev/null 2>&1 || true
      $CLAUDE mcp add --transport http gateway "${gatewayUrl}" --scope user >/dev/null
    fi
  '';
}
