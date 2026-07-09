{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.my;

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
    pkgs.runCommand "${name}.md"
      {
        nativeBuildInputs = [ pkgs.yq ];
        inherit (fm) frontmatter body;
      }
      ''
        tools=$(yq -y '.tools |= (map({(ascii_downcase):true}) | add)' <<<"$frontmatter")
        {
          printf '%s\n' '---'
          printf '%s\n' "$tools"
          printf '%s\n' '---'
          printf '%s\n' "$body"
        } > "$out"
      '';
in
{
  my.clis.opencode = {
    binary = "opencode";
    rulesFile = ".config/opencode/AGENTS.md";
    skillsDir = ".config/opencode/skills";
    agentsDir = ".config/opencode/agents";
    inherit buildAgent;
    gatewayFile = ".config/opencode/opencode.json";
    install = {
      kind = "github-release";
      repo = "anomalyco/opencode";
      assetByArch = {
        x86_64 = "opencode-linux-x64.tar.gz";
        aarch64 = "opencode-linux-arm64.tar.gz";
      };
      binaryInArchive = "opencode";
    };
  };

  home-manager.users.${cfg.username} = _: {
    home.file.".config/opencode/opencode.json".source = pkgs.replaceVars ./opencode.json {
      inherit (cfg) gatewayUrl;
    };
  };
}
