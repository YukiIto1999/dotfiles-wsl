{
  config,
  lib,
  pluginSources,
  ...
}:

let
  cfg = config.dotfiles.workstation;
  observationTimeoutSeconds = 10;
  homeManagerServiceName = "home-manager-${cfg.username}";
  homeManagerUnit = "${homeManagerServiceName}.service";
in
{
  config.dotfiles.health.observations = {
    "host/home-manager" = {
      kind = "systemd-service";
      checkId = "home-manager";
      resourceKey = null;
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "${homeManagerUnit} is not operational";
      unit = homeManagerUnit;
      loadStates = [ "loaded" ];
      activeStates = [ "active" ];
      results = [ "success" ];
    };
    "host/home-manager-restart" = {
      kind = "restart-counter";
      checkId = "restart/service/${homeManagerUnit}";
      resourceKey = null;
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "could not observe restart count for ${homeManagerUnit}";
      sourceKind = "systemd-service";
      target = homeManagerUnit;
      warningAt = 5;
      failureAt = 20;
    };
  };

  # Home Manager の activation は複数 unit の資材を配備する横断の入口
  config.environment.localBinInPath = true;
  config.home-manager.useGlobalPkgs = true;
  config.home-manager.useUserPackages = true;
  config.home-manager.backupFileExtension = "hm-back";
  config.home-manager.extraSpecialArgs = { inherit pluginSources; };

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
        direnv = {
          enable = true;
          enableBashIntegration = true;
          nix-direnv.enable = true;
        };
      };
  };
}
