{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.my;
  # template は valid JSON のまま保ち、動的な lsp block だけ module が足す
  opencodeBase = builtins.fromJSON (
    builtins.readFile (
      pkgs.replaceVars ./assets/opencode.json {
        gatewayUrl = config.dotfiles.mcp.gateway.url;
      }
    )
  );

  opencodeConfig = (pkgs.formats.json { }).generate "opencode.json" (
    opencodeBase
    // {
      lsp = lib.mapAttrs (
        _: server:
        {
          command = [ server.command ] ++ server.args;
          extensions = builtins.attrNames server.extensions;
        }
        // lib.optionalAttrs (server.initializationOptions != { }) {
          initialization = server.initializationOptions;
        }
      ) cfg.toolchain.lsp;
    }
  );

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

  my.artifacts."clis/opencode/config" = {
    format = "json";
    source = opencodeConfig;
  };

  home-manager.users.${cfg.username} = _: {
    home.file.".config/opencode/opencode.json".source = opencodeConfig;
  };
}
