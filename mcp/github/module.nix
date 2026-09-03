{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  githubTargets = builtins.attrNames (
    lib.filterAttrs (_: target: target.provider == "github") cfg.mcp.targets
  );
  expectedGithubTargets = lib.sort builtins.lessThan (
    map (account: "github-${account}") cfg.accounts
  );
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };

  toolsets = [
    "context"
    "issues"
    "pull_requests"
    "repos"
    "users"
  ];

  mkTarget =
    index: account:
    lib.nameValuePair "github-${account}" {
      provider = "github";
      executable = lib.getExe (
        pkgs.callPackage ./package.nix {
          inherit toolsets;
          serverBuilder = mkMcpServer;
          tokenFile = config.sops.secrets."accounts/${account}/token".path;
        }
      );
      serverLifecycle = "service";
      # 環境変数の PAT と両立しないリクエスト単位 OAuth の HTTP モード不採用
      port = 8780 + index;
      needsNetwork = true;
      probe = {
        tool = "get_me";
        args = { };
        timeout = 30;
      };
    };
in
{
  dotfiles.mcp.targets = lib.listToAttrs (lib.imap0 mkTarget cfg.accounts);

  # 起動後のトークン再読込に対応しない github-mcp-server の制約
  sops.secrets = lib.listToAttrs (
    map (account: {
      name = "accounts/${account}/token";
      value.restartUnits = [ "mcp-front-github-${account}.service" ];
    }) cfg.accounts
  );

  assertions = [
    {
      assertion = githubTargets == expectedGithubTargets;
      message = "GitHub target IDs must match github-<account> exactly";
    }
  ];
}
