{
  config,
  pkgs,
  lib,
  seedConfig,
  ...
}:

let
  cfg = config.my;

  codexModel = "gpt-5.6-sol";
  dotfilesHomeRelative = lib.removePrefix "${cfg.homeDir}/" cfg.dotfilesDir;
  dotfilesPathComponents = lib.splitString "/" dotfilesHomeRelative;
  dotfilesDirIsBelowHome =
    lib.hasPrefix "${cfg.homeDir}/" cfg.dotfilesDir
    && lib.all (
      component: component != "" && component != "." && component != ".."
    ) dotfilesPathComponents;
  codexProjectHomePath = "${dotfilesHomeRelative}/.codex/config.toml";
  codexProjectConfig = (pkgs.formats.toml { }).generate "codex-project-config.toml" {
    sandbox_workspace_write.writable_roots = [ "${cfg.dotfilesDir}/.git" ];
  };

  splitFrontmatter =
    src:
    let
      parts = lib.splitString "\n---\n" (builtins.readFile src);
    in
    {
      frontmatter = lib.removePrefix "---\n" (builtins.head parts);
      body = lib.concatStringsSep "\n---\n" (builtins.tail parts);
    };

  buildAgent =
    name: srcPath:
    let
      fm = splitFrontmatter srcPath;
    in
    pkgs.runCommand "${name}.toml"
      {
        nativeBuildInputs = [
          pkgs.remarshal
          pkgs.yq
        ];
        inherit (fm) frontmatter body;
      }
      ''
        yq -y 'del(.tools)' <<<"$frontmatter" | remarshal -if yaml -of toml > "$out"
        {
          printf 'model = "${codexModel}"\n'
          printf 'developer_instructions = """\n'
          printf '%s\n' "$body"
          printf '"""\n'
        } >> "$out"
      '';
in
{
  my.clis.codex = {
    binary = "codex";
    rulesFile = ".codex/AGENTS.md";
    skillsDir = ".codex/skills";
    agentsDir = ".codex/agents";
    inherit buildAgent;
    gatewayFile = null;
    install = {
      kind = "github-release";
      repo = "openai/codex";
      assetByArch = {
        x86_64 = "codex-x86_64-unknown-linux-musl.tar.gz";
        aarch64 = "codex-aarch64-unknown-linux-musl.tar.gz";
      };
    };
  };

  # codex の workspace-write sandbox が PATH 上に要求する bubblewrap
  environment.systemPackages = [ pkgs.bubblewrap ];

  assertions = [
    {
      assertion = dotfilesDirIsBelowHome;
      message = "my.dotfilesDir must be a normalized path below my.homeDir for Codex project config deployment";
    }
  ];

  # codex は user seed の ~/.codex/config.toml をこの上に merge
  # gateway と hooks は全 project 共通、checkout の Git 権限は trusted project config に限定
  environment.etc."codex/config.toml".source = pkgs.replaceVars ./config-system.toml {
    inherit (cfg) gatewayUrl;
  };

  home-manager.users.${cfg.username} =
    { lib, ... }:
    {
      home.file.${codexProjectHomePath}.source = codexProjectConfig;
      home.activation.seedCodexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        seedConfig ".codex/config.toml" (pkgs.replaceVars ./config.toml { inherit codexModel; })
      );
    };
}
