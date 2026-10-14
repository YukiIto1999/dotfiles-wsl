{
  configuration = [
    (
      {
        pkgs,
        hostConfig,
        ...
      }:
      let
        front = hostConfig.dotfiles.platform.mcp.fronts.chrome-devtools;
        service = hostConfig.systemd.services.${front.service}.serviceConfig;
      in
      {
        chrome-devtools-front =
          assert hostConfig.dotfiles.platform.mcp.targets.chrome-devtools.needsNetwork;
          assert service.RuntimeDirectoryMode == "0700";
          assert !(service.PrivateTmp or false);
          pkgs.runCommandLocal "check-chrome-devtools-front" { } ''
            touch $out
          '';
      }
    )
  ];
}
