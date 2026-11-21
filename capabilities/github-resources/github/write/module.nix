{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "github-resources" config.dotfiles.capabilities.resolved;
  inherit (config.dotfiles.identity.github) accounts;
in
{
  # 依頼された通常の書込を、起動中のセッションから account を固定した公式 gh で一度だけ送る。
  # 読取は共有の読取専用 target が持ち、merge、削除、history の変更は書込用セッションに残す
  config = lib.mkIf enabled {
    dotfiles.platform.cli.commands.githubWrite = pkgs.callPackage ./package.nix {
      accounts = lib.genAttrs accounts (account: config.sops.secrets."accounts/${account}/token".path);
    };
  };
}
