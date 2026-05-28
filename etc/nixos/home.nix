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
      counts = builtins.foldl' (acc: n:
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

  # CLI definitions
  cliDefs = {
    claude = {
      skillDir   = ".claude/skills";
      agentDir   = ".claude/agents";
      agentExt   = "md";
      buildAgent = _: srcPath: pkgs.replaceVars ../../templates/agent-claude.md {
        agentBody = builtins.readFile srcPath;
      };
    };
    codex = {
      skillDir   = ".codex/skills";
      agentDir   = ".codex/agents";
      agentExt   = "toml";
      buildAgent = name: srcPath: pkgs.runCommand "${name}.toml" {
        nativeBuildInputs = [ pkgs.remarshal pkgs.gawk pkgs.gnused ];
      } ''
        set -euo pipefail
        src=${srcPath}
        tpl=${../../templates/agent-codex.toml}
        awk '/^---$/{c++; next} c==1' "$src" > fm.yaml
        remarshal -if yaml -of toml fm.yaml > fm.toml
        awk '/^---$/{c++; next} c>=2' "$src" > body.txt
        sed -i 's/&/\\&/g' fm.toml body.txt
        awk -v fm_file=fm.toml -v body_file=body.txt '
          BEGIN {
            while ((getline l < fm_file)  > 0) fm = fm (fm == "" ? "" : "\n") l
            while ((getline l < body_file) > 0) bd = bd (bd == "" ? "" : "\n") l
          }
          { gsub(/@frontmatter@/, fm); gsub(/@body@/, bd); print }
        ' "$tpl" > "$out"
      '';
    };
    opencode = {
      skillDir   = ".config/opencode/skills";
      agentDir   = ".config/opencode/agents";
      agentExt   = "md";
      buildAgent = name: srcPath: pkgs.runCommand "${name}.md" {
        nativeBuildInputs = [ pkgs.yq ];
      } ''
        awk '/^---$/{c++;next} c==1' ${srcPath} \
          | yq -y '.tools |= (map({(.):true})|add)' > fm.yaml
        awk '/^---$/{c++;next} c>=2' ${srcPath} > body.md
        { echo '---'; cat fm.yaml; echo '---'; cat body.md; } > $out
      '';
    };
    antigravity = {
      skillDir   = ".gemini/antigravity-cli/skills";
      agentDir   = ".gemini/agents";
      agentExt   = "md";
      buildAgent = _: srcPath: pkgs.replaceVars ../../templates/agent-antigravity.md {
        agentBody = builtins.readFile srcPath;
      };
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
  agentsBody  = builtins.readFile (../../share/AGENTS.md);
  mkDupAssert = label: dupes: {
    assertion = dupes == [ ];
    message   = "Duplicate skill names ${label}: " + lib.concatStringsSep ", " dupes;
  };
  mkGitHook = name: {
    source     = ../../home/nixos/.config/git/hooks + "/${name}";
    executable = true;
  };

  # Root config files
  rootFiles = {
    # Claude Code
    ".claude/CLAUDE.md".source     = pkgs.replaceVars ../../home/nixos/.claude/CLAUDE.md     { inherit agentsBody; };
    ".claude/settings.json".source = ../../home/nixos/.claude/settings.json;
    # Codex CLI
    ".codex/AGENTS.md".source      = pkgs.replaceVars ../../home/nixos/.codex/AGENTS.md      { inherit agentsBody; };
    ".codex/config.toml".source    = pkgs.replaceVars ../../home/nixos/.codex/config.toml    { inherit gatewayUrl; };
    # OpenCode
    ".config/opencode/AGENTS.md".source     = pkgs.replaceVars ../../home/nixos/.config/opencode/AGENTS.md     { inherit agentsBody; };
    ".config/opencode/opencode.json".source = pkgs.replaceVars ../../home/nixos/.config/opencode/opencode.json { inherit gatewayUrl; };
    # Antigravity CLI
    ".gemini/AGENTS.md".source                       = pkgs.replaceVars ../../home/nixos/.gemini/AGENTS.md                       { inherit agentsBody; };
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

  # Claude only: register gateway via `claude mcp add` (settings.json ignores mcpServers)
  home.activation.claudeMcpRegister = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    CLAUDE=$HOME/.local/bin/claude
    [ -x "$CLAUDE" ] || exit 0
    $CLAUDE mcp remove gateway --scope user >/dev/null 2>&1 || true
    $CLAUDE mcp add --transport http gateway "${gatewayUrl}" --scope user >/dev/null
  '';
}
