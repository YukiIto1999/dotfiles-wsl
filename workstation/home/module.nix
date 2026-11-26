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
  # 退避先が既にあると Home Manager は activation を止める。旧構成は dotfiles-cleanup で古い退避を消して解いていたため、
  # 同じ結果を標準の option で自動にし、最新の退避を一つだけ残す
  config.home-manager.overwriteBackup = true;

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
