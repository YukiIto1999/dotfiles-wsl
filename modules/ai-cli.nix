{ config, pkgs, ... }:

let
  cfg = config.my;
in
{
  environment.etc."claude-code/managed-settings.json".source =
    ../home/nixos/.claude/managed-settings.json;

  # codex は user seed の ~/.codex/config.toml をこの上に merge
  # gateway は seed でなくここに置き gatewayUrl 変更を常に反映
  environment.etc."codex/config.toml".source =
    pkgs.replaceVars ../home/nixos/.codex/config-system.toml { inherit (cfg) gatewayUrl; };
}
