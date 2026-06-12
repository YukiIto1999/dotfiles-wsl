{ config, pkgs, lib, osConfig, pluginSources, ... }:

# Deploy one shared set of rules, agents and skills to every AI CLI.
# share/AGENTS.md, share/agents/*.md and the discovered skills are converted to
# each CLI's native layout and pointed at the same MCP gateway.

let
  my          = osConfig.my;
  homeDir     = "/home/${my.username}";
  dotfilesAbs = "${homeDir}/dotfiles-wsl";
  symlink     = config.lib.file.mkOutOfStoreSymlink;
  gatewayUrl  = my.gatewayUrl;

  # Skill discovery
  pluginPaths = [
    "${pluginSources.superpowers}"
    "${pluginSources.openai-plugins}/plugins/codex-security"
    "${pluginSources.claude-plugins-official}/plugins/frontend-design"
    "${pluginSources.claude-plugins-official}/plugins/skill-creator"
  ];

  findSkillsIn = pluginPath:
    let
      skillsRoot = "${pluginPath}/skills";
      entries =
        if builtins.pathExists skillsRoot
        then builtins.readDir skillsRoot
        else { };
      dirs = lib.filterAttrs (n: t:
        t == "directory" && builtins.pathExists "${skillsRoot}/${n}/SKILL.md"
      ) entries;
    in
      lib.mapAttrs' (name: _: lib.nameValuePair name "${skillsRoot}/${name}") dirs;

  pluginSkills = lib.foldl' (acc: p: acc // (findSkillsIn p)) { } pluginPaths;
  pluginSkillDupes =
    let
      flat   = lib.concatMap (p: builtins.attrNames (findSkillsIn p)) pluginPaths;
      counts = lib.foldl' (acc: n: acc // { ${n} = (acc.${n} or 0) + 1; }) { } flat;
    in
      builtins.attrNames (lib.filterAttrs (_: c: c > 1) counts);
  localSkills = lib.mapAttrs' (name: _:
      lib.nameValuePair name "${dotfilesAbs}/share/skills/${name}"
    ) (lib.filterAttrs (n: t:
         t == "directory" && builtins.pathExists (../share/skills + "/${n}/SKILL.md")
       ) (builtins.readDir ../share/skills));
  localVsPluginDupes =
    builtins.filter (n: builtins.hasAttr n pluginSkills) (builtins.attrNames localSkills);
  allSkills = pluginSkills // localSkills;

  # Per-CLI agent layout
  splitFrontmatter = src:
    let parts = lib.splitString "\n---\n" (builtins.readFile src);
    in {
      frontmatter = lib.removePrefix "---\n" (builtins.head parts);
      body        = lib.concatStringsSep "\n---\n" (builtins.tail parts);
    };
  codexModel = "gpt-5.5";

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
          nativeBuildInputs = [ pkgs.remarshal ];
          inherit (fm) frontmatter body;
        } ''
          remarshal -if yaml -of toml <<<"$frontmatter" > "$out"
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
          tools=$(yq -y '.tools |= (map({(.):true}) | add)' <<<"$frontmatter")
          {
            printf '%s\n' '---'
            printf '%s\n' "$tools"
            printf '%s\n' '---'
            printf '%s\n' "$body"
          } > "$out"
        '';
    };
    antigravity = {
      skillDir   = ".gemini/antigravity-cli/skills";
      agentDir   = ".gemini/agents";
      agentExt   = "md";
      buildAgent = _: srcPath: srcPath;
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

  agentFiles = lib.listToAttrs (lib.concatMap (cli:
      let def = cliDefs.${cli}; in
      lib.mapAttrsToList (name: srcPath: {
        name  = "${def.agentDir}/${name}.${def.agentExt}";
        value = { source = def.buildAgent name srcPath; };
      }) agents
    ) (builtins.attrNames cliDefs));

  # The shared rules and per-CLI gateway registration
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
    f="${homeDir}/${rel}"
    if [ -L "$f" ] || [ ! -e "$f" ]; then
      rm -f "$f"
      install -Dm600 ${src} "$f"
    fi
  '';
in
{
  assertions = [
    (mkDupAssert "between local and plugins" localVsPluginDupes)
    (mkDupAssert "across plugins" pluginSkillDupes)
  ];

  home.file = ruleFiles // skillFiles // agentFiles;

  home.activation.seedMutableConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    seedConfig ".claude/settings.json" ./nixos/.claude/settings.json
    + seedConfig ".codex/config.toml" ./nixos/.codex/config.toml
  );

  # Register the gateway with Claude Code when it is installed. A plain if-guard,
  # not `exit`, so it never aborts the rest of the activation script.
  home.activation.claudeMcpRegister = lib.hm.dag.entryAfter [ "seedMutableConfigs" ] ''
    CLAUDE=$HOME/.local/bin/claude
    if [ -x "$CLAUDE" ]; then
      $CLAUDE mcp remove gateway --scope user >/dev/null 2>&1 || true
      $CLAUDE mcp add --transport http gateway "${gatewayUrl}" --scope user >/dev/null
    fi
  '';
}
