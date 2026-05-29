{ config, lib, pkgs, username, pluginSources, gatewayUrl, workIdentity, ... }:

let
  # Paths
  homeDir      = config.home.homeDirectory;
  dotfilesAbs  = "${homeDir}/dotfiles-wsl";
  symlink      = config.lib.file.mkOutOfStoreSymlink;

  # Skills
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
        t == "directory"
        && builtins.pathExists "${skillsRoot}/${n}/SKILL.md"
      ) entries;
    in
      lib.mapAttrs' (name: _:
        lib.nameValuePair name "${skillsRoot}/${name}"
      ) dirs;

  pluginSkills     = lib.foldl' (acc: p: acc // (findSkillsIn p)) { } pluginPaths;
  pluginSkillDupes =
    let
      flat = lib.concatMap (p: builtins.attrNames (findSkillsIn p)) pluginPaths;
      counts = lib.foldl' (acc: n:
        acc // { ${n} = (acc.${n} or 0) + 1; }
      ) { } flat;
    in
      builtins.attrNames (lib.filterAttrs (_: c: c > 1) counts);
  localSkills      = lib.mapAttrs' (name: _:
      lib.nameValuePair name "${dotfilesAbs}/share/skills/${name}"
    ) (lib.filterAttrs (n: t:
         t == "directory"
         && builtins.pathExists (../../share/skills + "/${n}/SKILL.md")
       ) (builtins.readDir ../../share/skills));
  localVsPluginDupes =
    builtins.filter (n: builtins.hasAttr n pluginSkills)
      (builtins.attrNames localSkills);
  allSkills        = pluginSkills // localSkills;

  # Agent frontmatter
  splitFrontmatter = src:
    let parts = lib.splitString "\n---\n" (builtins.readFile src);
    in {
      frontmatter = lib.removePrefix "---\n" (builtins.head parts);
      body        = lib.concatStringsSep "\n---\n" (builtins.tail parts);
    };
  codexModel = "gpt-5.5";

  # CLI definitions
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

  # Skill files for all CLIs
  skillFiles = lib.listToAttrs (lib.concatMap (cli:
      let def = cliDefs.${cli}; in
      lib.mapAttrsToList (name: src: {
        name  = "${def.skillDir}/${name}";
        value = { source = symlink src; };
      }) allSkills
    ) (builtins.attrNames cliDefs));

  # Agents
  agents = lib.mapAttrs' (filename: _:
      let baseName = lib.removeSuffix ".md" filename;
      in lib.nameValuePair baseName (../../share/agents + "/${filename}")
    ) (lib.filterAttrs (n: t:
         t == "regular" && (lib.hasSuffix ".md" n)
       ) (builtins.readDir ../../share/agents));

  # Agent files for all CLIs
  agentFiles = lib.listToAttrs (lib.concatMap (cli:
      let def = cliDefs.${cli}; in
      lib.mapAttrsToList (name: srcPath: {
        name  = "${def.agentDir}/${name}.${def.agentExt}";
        value = { source = def.buildAgent name srcPath; };
      }) agents
    ) (builtins.attrNames cliDefs));

  # Helpers
  mkDupAssert = label: dupes: {
    assertion = dupes == [ ];
    message   = "Duplicate skill names ${label}: " + lib.concatStringsSep ", " dupes;
  };
  mkGitHook = name: {
    source     = ../../home/nixos/.config/git/hooks + "/${name}";
    executable = true;
  };
  seedConfig = rel: src: ''
    f="${homeDir}/${rel}"
    if [ -L "$f" ] || [ ! -e "$f" ]; then
      rm -f "$f"
      install -Dm600 ${src} "$f"
    fi
  '';

  # Root config files
  rootFiles = {
    # Claude Code
    ".claude/CLAUDE.md".source     = ../../share/AGENTS.md;
    # Codex CLI
    ".codex/AGENTS.md".source      = ../../share/AGENTS.md;
    # OpenCode
    ".config/opencode/AGENTS.md".source     = ../../share/AGENTS.md;
    ".config/opencode/opencode.json".source = pkgs.replaceVars ../../home/nixos/.config/opencode/opencode.json { inherit gatewayUrl; };
    # Antigravity CLI
    ".gemini/AGENTS.md".source                       = ../../share/AGENTS.md;
    ".gemini/antigravity-cli/mcp_config.json".source = pkgs.replaceVars ../../home/nixos/.gemini/antigravity-cli/mcp_config.json { inherit gatewayUrl; };
    # Git
    ".config/git/ignore".source    = symlink "${dotfilesAbs}/home/nixos/.config/git/ignore";
    ".config/git/hooks/pre-commit" = mkGitHook "pre-commit";
    ".config/git/hooks/commit-msg" = mkGitHook "commit-msg";
  };
in
{
  # User
  home.username      = username;
  home.homeDirectory = "/home/${username}";
  home.stateVersion  = "25.11";

  # Asserts
  assertions = [
    (mkDupAssert "between local and plugins" localVsPluginDupes)
    (mkDupAssert "across plugins" pluginSkillDupes)
  ];

  # Packages
  home.packages = with pkgs; [
    # Lang
    nodejs_24
    uv

    # Browser
    chromium

    # CLI
    ripgrep
    fd
    jq
    yq
    xh

    # Quality
    shellcheck
    shfmt
    just

    # Nix
    nixfmt-rfc-style
    nixd
    nvd
  ];

  home.sessionVariables.BROWSER = "wslview";
  home.sessionPath = [ "$HOME/.local/bin" ];

  # Programs
  programs = {
    git = {
      enable = true;
      settings = {
        init.defaultBranch  = "main";
        pull.rebase         = false;
        core.excludesFile   = "~/.config/git/ignore";
        core.hooksPath      = "~/.config/git/hooks";
        merge.conflictstyle = "diff3";
        include.path        = "${homeDir}/.config/git/identity.conf";
      };
      includes = lib.optionals (workIdentity != null) [
        { condition = "gitdir:${workIdentity}";
          path      = "${homeDir}/.config/git/work-identity.conf"; }
      ];
    };

    delta = {
      enable               = true;
      enableGitIntegration = true;
      options = {
        navigate     = true;
        side-by-side = true;
      };
    };
  } // lib.genAttrs [ "gh" "bash" "fzf" "zoxide" "bat" "eza" ] (_: { enable = true; });

  # Files
  home.file = rootFiles // skillFiles // agentFiles;

  # CLI
  home.activation.seedMutableConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    seedConfig ".claude/settings.json" ../../home/nixos/.claude/settings.json
    + seedConfig ".codex/config.toml"   ../../home/nixos/.codex/config.toml
  );
  home.activation.claudeMcpRegister = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    CLAUDE=$HOME/.local/bin/claude
    [ -x "$CLAUDE" ] || exit 0
    $CLAUDE mcp remove gateway --scope user >/dev/null 2>&1 || true
    $CLAUDE mcp add --transport http gateway "${gatewayUrl}" --scope user >/dev/null
  '';
}
