{ config, pkgs, lib, seedConfig, ... }:

let
  cfg = config.my;

  # 生成 agent TOML に焼き込むモデル。config.toml の model / tui.model_availability_nux も同じ定数
  codexModel = "gpt-5.5";

  # agent frontmatter の分割
  splitFrontmatter = src:
    let parts = lib.splitString "\n---\n" (builtins.readFile src);
    in {
      frontmatter = lib.removePrefix "---\n" (builtins.head parts);
      body        = lib.concatStringsSep "\n---\n" (builtins.tail parts);
    };

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
in
{
  my.clis.codex = {
    binary      = "codex";
    rulesFile   = ".codex/AGENTS.md";
    skillsDir   = ".codex/skills";
    agentsDir   = ".codex/agents";
    inherit buildAgent;
    gatewayFile = null;
    install     = {
      kind = "github-release";
      repo = "openai/codex";
      assetByArch = {
        x86_64  = "codex-x86_64-unknown-linux-musl.tar.gz";
        aarch64 = "codex-aarch64-unknown-linux-musl.tar.gz";
      };
    };
  };

  # codex は user seed の ~/.codex/config.toml をこの上に merge
  # gateway は seed でなくここに置き gatewayUrl 変更を常に反映
  environment.etc."codex/config.toml".source =
    pkgs.replaceVars ./config-system.toml { inherit (cfg) gatewayUrl; };

  home-manager.users.${cfg.username} = { lib, ... }: {
    home.activation.seedCodexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      seedConfig ".codex/config.toml" (pkgs.replaceVars ./config.toml { inherit codexModel; })
    );
  };
}
