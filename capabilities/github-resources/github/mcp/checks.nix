{
  lib,
  pkgs,
  hostConfig,
  ...
}:

let
  fixtureAccounts = [
    "fixture-a"
    "fixture-b"
  ];
  mkFixtureTarget = account: lib.nameValuePair "github-${account}" { provider = "github"; };
  fixtureTargets = builtins.listToAttrs (map mkFixtureTarget fixtureAccounts);

  assertionsPass =
    accounts: candidateTargets:
    let
      evaluation = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [
          ./module.nix
          (
            { lib, ... }:
            {
              options = {
                dotfiles.identity.github.accounts = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                };
                dotfiles.platform.mcp.targets = lib.mkOption {
                  type = lib.types.attrsOf lib.types.raw;
                  default = { };
                };
                assertions = lib.mkOption {
                  type = lib.types.listOf lib.types.raw;
                  default = [ ];
                };
                sops.secrets = lib.mkOption {
                  type = lib.types.attrsOf lib.types.raw;
                  default = { };
                };
              };

              config = {
                dotfiles.identity.github.accounts = accounts;
                dotfiles.platform.mcp.targets = lib.mkForce candidateTargets;
              };
            }
          )
        ];
      };
      result = builtins.tryEval (
        builtins.deepSeq evaluation.config.assertions (
          lib.all (entry: entry.assertion) evaluation.config.assertions
        )
      );
    in
    result.success && result.value;

  missingTarget = builtins.removeAttrs fixtureTargets [ "github-fixture-b" ];
  extraTarget = fixtureTargets // {
    github-extra.provider = "github";
  };
  renamedTarget = builtins.removeAttrs fixtureTargets [ "github-fixture-b" ] // {
    github-renamed = fixtureTargets.github-fixture-b;
  };

  accounts = hostConfig.dotfiles.identity.github.accounts;
  githubTargetNames = builtins.attrNames (
    lib.filterAttrs (_: target: target.provider == "github") hostConfig.dotfiles.platform.mcp.targets
  );
  expectedTargetNames = lib.sort builtins.lessThan (map (account: "github-${account}") accounts);
in
{
  github-account-target-contract =
    assert githubTargetNames == expectedTargetNames;
    assert assertionsPass fixtureAccounts fixtureTargets;
    assert !(assertionsPass fixtureAccounts missingTarget);
    assert !(assertionsPass fixtureAccounts extraTarget);
    assert !(assertionsPass fixtureAccounts renamedTarget);
    pkgs.runCommandLocal "check-github-account-target-contract" { } "touch $out";
}
