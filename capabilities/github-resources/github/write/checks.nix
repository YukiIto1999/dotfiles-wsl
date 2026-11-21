{ pkgs, lib, ... }:
let
  # 実 account の token を使わない。gh の開発用 host へ向けた同じ命令を合成の API に当てる
  fixtureToken = name: value: pkgs.writeText "fixture-github-token-${name}" value;
  fixtureCommand = pkgs.callPackage ./package.nix {
    githubHost = "github.localhost";
    accounts = {
      fixture-a = fixtureToken "a" "synthetic-token-a";
      fixture-b = fixtureToken "b" "synthetic-token-b";
      fixture-empty = fixtureToken "empty" "";
      fixture-missing = "/nonexistent/fixture-github-token";
    };
  };
in
{
  source = [
    {
      github-write-contract =
        pkgs.runCommandLocal "check-github-write-contract" { nativeBuildInputs = [ pkgs.python3 ]; }
          ''
            python3 ${./fixtures/write-contract.py} ${lib.getExe fixtureCommand}
            touch "$out"
          '';
    }
  ];

  configuration = [
    (
      { lib, hostConfig, ... }:
      let
        inherit (hostConfig.dotfiles.identity.github) accounts;
        inherit (hostConfig.dotfiles.workstation) username;
        command = hostConfig.dotfiles.platform.cli.commands.githubWrite;
        tokenPath = account: hostConfig.sops.secrets."accounts/${account}/token".path;
        homeGh = hostConfig.home-manager.users.${username}.programs.gh.package;
      in
      {
        # 共有の読取 target github-<account> と同じ account id が、同じ token file を指す。
        # token を読めるのは managed credential を持つ利用者自身で、選んだ token 以外へ切り替えない
        github-write-wiring =
          assert accounts != [ ];
          assert command.githubWriteHost == "github.com";
          assert command.githubWriteAccounts == lib.genAttrs accounts tokenPath;
          assert lib.all (account: lib.hasPrefix "/" (tokenPath account)) accounts;
          assert lib.all (
            account: hostConfig.sops.secrets."accounts/${account}/token".owner == username
          ) accounts;
          assert lib.all (
            account: builtins.hasAttr "github-${account}" hostConfig.dotfiles.platform.mcp.targets
          ) accounts;
          assert command.githubWriteGh.outPath == homeGh.outPath;
          pkgs.runCommandLocal "check-github-write-wiring" { } "touch $out";
      }
    )
  ];
}
