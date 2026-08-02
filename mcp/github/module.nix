{
  config,
  lib,
  pkgs,
  mkMcpServer,
  serveOverProxy,
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
    index: account:
    lib.nameValuePair "github-${account}" {
      # http mode は request ごとの OAuth を要求し、PAT を環境変数で持つ形と噛み合わない
      port = 8780 + index;
      # api.github.com へ出る
      needsNetwork = true;
      serve = serveOverProxy (
        lib.getExe (
          pkgs.callPackage ./package.nix {
            inherit mkMcpServer toolsets;
            tokenFile = config.sops.secrets."accounts/${account}/token".path;
          }
        )
      );
    };
in
{
  my.mcp.targets = lib.listToAttrs (lib.imap0 mkTarget cfg.accounts);

  # front は起動時に一度だけ token を読む。rotation を拾うには再起動が要る
  sops.secrets = lib.listToAttrs (
    map (account: {
      name = "accounts/${account}/token";
      value.restartUnits = [ "mcp-front-github-${account}.service" ];
    }) cfg.accounts
  );
}
