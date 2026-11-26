{
  config,
  lib,
  ...
}:

let
  cfg = config.dotfiles.workstation;
in
{
  # Home Manager の activation は複数 unit の資材を配備する横断の入口
  config.environment.localBinInPath = true;
  config.home-manager.useGlobalPkgs = true;
  config.home-manager.useUserPackages = true;
  config.home-manager.backupFileExtension = "hm-back";

  config.home-manager.users.${cfg.username} = _: {
    home.stateVersion = "25.11";

    home.sessionVariables.BROWSER = "wslview";
    home.sessionPath = [ "$HOME/.local/bin" ];

    programs =
      lib.genAttrs
        [
          "gh"
          "bash"
          "fzf"
          "zoxide"
          "bat"
          "eza"
        ]
        (_: {
          enable = true;
        })
      // {
        atuin = {
          enable = true;
          enableBashIntegration = true;
          settings = {
            auto_sync = false;
            update_check = false;
          };
        };
        direnv = {
          enable = true;
          enableBashIntegration = true;
          nix-direnv.enable = true;
        };
      };
  };
}
