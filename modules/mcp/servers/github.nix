{ config, lib, pkgs, mkMcpServer, ... }:

# account ごとに 1 instance、PAT は spawn 時に sops file から読む
let
  cfg = config.my;

  mkTarget = account: lib.nameValuePair "github-${account}" {
    command = lib.getExe (pkgs.callPackage ../../../pkgs/github-mcp {
      inherit mkMcpServer;
      tokenFile = config.sops.secrets."accounts/${account}/token".path;
    });
  };
in
{
  my.mcp.targets = lib.listToAttrs (map mkTarget cfg.accounts);
}
