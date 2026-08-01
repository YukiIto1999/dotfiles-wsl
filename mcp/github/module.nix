{
  config,
  lib,
  pkgs,
  mkMcpServer,
  ...
}:

# account ごとに 1 instance、PAT は spawn 時に sops file から読む
let
  cfg = config.my;

  # upstream default から copilot を除いた採用 toolset
  toolsets = [
    "context"
    "issues"
    "pull_requests"
    "repos"
    "users"
  ];

  mkTarget =
    account:
    lib.nameValuePair "github-${account}" {
      command = lib.getExe (
        pkgs.callPackage ./package.nix {
          inherit mkMcpServer toolsets;
          tokenFile = config.sops.secrets."accounts/${account}/token".path;
        }
      );
    };
in
{
  my.mcp.targets = lib.listToAttrs (map mkTarget cfg.accounts);
}
