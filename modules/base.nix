{ config, pkgs, ... }:

let
  cfg = config.my;
in
{
  # "docker" is added by mcp.nix, which owns the docker stack.
  users.users.${cfg.username} = {
    isNormalUser = true;
    home = "/home/${cfg.username}";
    extraGroups = [ "wheel" ];
  };

  environment.systemPackages = with pkgs; [
    wget
    curl
    vim
    wslu
    direnv
    nix-direnv
    devenv
    sops
    age
  ];

  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    nix-direnv.enable = true;
  };

  # AI CLI system-level settings. The rest of each CLI's config is Home Manager.
  environment.etc."claude-code/managed-settings.json".source =
    ../home/nixos/.claude/managed-settings.json;
  environment.etc."codex/config.toml".source =
    pkgs.replaceVars ../home/nixos/.codex/config-system.toml { gatewayUrl = cfg.gatewayUrl; };

  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
    ];
    fontconfig = {
      enable = true;
      defaultFonts = {
        serif     = [ "Noto Serif CJK JP" "Noto Serif" ];
        sansSerif = [ "Noto Sans CJK JP" "Noto Sans" ];
        monospace = [ "Noto Sans Mono CJK JP" "Noto Sans Mono" ];
        emoji     = [ "Noto Color Emoji" ];
      };
    };
  };
}
