{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  enabled = builtins.elem "github-resources" config.dotfiles.capabilities.resolved;
  cfg = config.dotfiles.identity.github;
  githubTargets = builtins.attrNames (
    lib.filterAttrs (_: target: target.provider == "github") config.dotfiles.platform.mcp.targets
  );
  expectedGithubTargets = lib.sort builtins.lessThan (
    map (account: "github-${account}") cfg.accounts
  );
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  accountServer =
    account: readOnly:
    lib.getExe (
      pkgs.callPackage ./package.nix {
        inherit readOnly;
        toolsets = toolsets ++ lib.optional readOnly "actions";
        excludeTools = lib.optionals (!readOnly) commandOwnedTools;
        githubMcpServer =
          self.inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.github-mcp-server;
        serverBuilder = mkMcpServer;
        tokenFile = config.sops.secrets."accounts/${account}/token".path;
      }
    );

  # 起動中のセッションの命令だけで全入力を扱える tool は書込用セッションに重ねない
  commandOwnedTools = [
    "add_issue_comment"
    "create_branch"
    "update_issue_comment"
  ];

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
      executable = accountServer account true;
      exposure = "default";
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
  config = lib.mkIf enabled {
    dotfiles.platform.mcp.targets = lib.listToAttrs (lib.imap0 mkTarget cfg.accounts);
    dotfiles.platform.mcp.privateServers = lib.listToAttrs (
      map (
        account: lib.nameValuePair "github-write-${account}" { executable = accountServer account false; }
      ) cfg.accounts
    );

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
  };
}
