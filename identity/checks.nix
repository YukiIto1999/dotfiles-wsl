{
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  variantConfig,
  mkNixosSystem,
  normalMachineModule,
  ...
}:

let
  accounts = hostConfig.dotfiles.identity.github.accounts;
  owners = hostConfig.dotfiles.identity.github.owners;
  accountArtifact = hostConfig.dotfiles.managedArtifacts."accounts/gh-hosts";
  accountTemplate = hostConfig.sops.templates."gh-hosts.yml";
  gitIdentity = hostConfig.dotfiles.toolchain.git.identity;
  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.workstation.username};
  homeDir = hostConfig.dotfiles.workstation.homeDir;
  variantTemplate = variantConfig.sops.templates."gh-hosts.yml";
  primary = hostConfig.dotfiles.identity.github.primary;
  storeFile = hostConfig.sops.defaultSopsFile;
  noWorkIdentityConfig =
    (mkNixosSystem [
      normalMachineModule
      { dotfiles.toolchain.git.workIdentity = lib.mkForce null; }
    ]).config;
  noWorkIdentityHome =
    noWorkIdentityConfig.home-manager.users.${noWorkIdentityConfig.dotfiles.workstation.username};
  identityDestinationType = hostOptions.dotfiles.toolchain.git.identity.destinations.default.type;

  # 実 account を使わない store。導出は key の有無だけを読む
  fixtureStorePaths = [
    "accounts/fixture-a/primary"
    "accounts/fixture-a/token"
    "accounts/fixture-a/username"
    "accounts/fixture-b/owners/fixture-org"
    # primary という名前の owner は primary の印ではない
    "accounts/fixture-b/owners/primary"
    "accounts/fixture-b/token"
    "accounts/fixture-b/username"
    "accounts/fixture-c/owners/fixture-lab"
    "accounts/fixture-c/owners/fixture-team"
    "accounts/fixture-c/token"
    "accounts/fixture-c/username"
    "identity/default/name"
  ];
  evalFixtureIdentity =
    storePaths:
    (lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        ./module.nix
        (
          { lib, ... }:
          {
            options = {
              dotfiles.secrets.paths = lib.mkOption {
                type = lib.types.listOf lib.types.str;
              };
              dotfiles.workstation = lib.mkOption {
                type = lib.types.raw;
              };
              dotfiles.toolchain.git = lib.mkOption {
                type = lib.types.raw;
              };
              dotfiles.managedArtifacts = lib.mkOption {
                type = lib.types.attrsOf lib.types.raw;
                default = { };
              };
              sops.placeholder = lib.mkOption {
                type = lib.types.attrsOf lib.types.raw;
                default = { };
              };
              sops.secrets = lib.mkOption {
                type = lib.types.attrsOf lib.types.raw;
                default = { };
              };
              sops.templates = lib.mkOption {
                type = lib.types.attrsOf lib.types.raw;
                default = { };
              };
              assertions = lib.mkOption {
                type = lib.types.listOf lib.types.raw;
                default = [ ];
              };
            };
            config = {
              dotfiles.secrets.paths = storePaths;
              dotfiles.workstation = {
                inherit homeDir;
                inherit (hostConfig.dotfiles.workstation) username;
              };
              dotfiles.toolchain.git = {
                identity = gitIdentity;
                workIdentity = null;
              };
            };
          }
        )
      ];
    }).config;
  fixtureIdentity = evalFixtureIdentity fixtureStorePaths;
  fixtureAssertionsPass =
    storePaths:
    let
      result = builtins.tryEval (
        let
          inherit (evalFixtureIdentity storePaths) assertions;
        in
        builtins.deepSeq assertions (lib.all (entry: entry.assertion) assertions)
      );
    in
    result.success && result.value;
  fixtureOwnersEvaluate =
    storePaths:
    (builtins.tryEval (
      builtins.deepSeq (evalFixtureIdentity storePaths).dotfiles.identity.github.owners true
    )).success;
in
{
  account-deployment-contract =
    assert accounts != [ ];
    assert builtins.elem primary accounts;
    assert variantTemplate.content == accountTemplate.content;
    assert accountTemplate.content == builtins.readFile accountArtifact.source;
    assert
      hostConfig.sops.templates."git-identity".path == "${homeDir}/${gitIdentity.destinations.default}";
    assert
      hostConfig.sops.templates."git-work-identity".path == "${homeDir}/${gitIdentity.destinations.work}";
    assert
      homeConfig.programs.git.settings.include.path == "${homeDir}/${gitIdentity.destinations.default}";
    assert
      (builtins.head homeConfig.programs.git.includes).path
      == "${homeDir}/${gitIdentity.destinations.work}";
    assert !(noWorkIdentityConfig.sops.templates ? "git-work-identity");
    assert !(noWorkIdentityConfig.sops.secrets ? "identity/work/name");
    assert !(noWorkIdentityConfig.sops.secrets ? "identity/work/email");
    assert noWorkIdentityHome.programs.git.includes == [ ];
    assert
      noWorkIdentityConfig.sops.templates."git-identity".path
      == "${noWorkIdentityConfig.dotfiles.workstation.homeDir}/${gitIdentity.destinations.default}";
    assert identityDestinationType.check ".config/git/identity.conf";
    assert !(identityDestinationType.check "");
    assert !(identityDestinationType.check "/outside");
    assert !(identityDestinationType.check "../outside");
    assert !(identityDestinationType.check "safe/../outside");
    assert !(identityDestinationType.check "safe//outside");
    assert !(identityDestinationType.check "safe\noutside");
    assert owners.${primary} == [ ];
    assert
      fixtureIdentity.dotfiles.identity.github.owners == {
        fixture-a = [ ];
        fixture-b = [
          "fixture-org"
          "primary"
        ];
        fixture-c = [
          "fixture-lab"
          "fixture-team"
        ];
      };
    assert fixtureIdentity.dotfiles.identity.github.primary == "fixture-a";
    assert fixtureAssertionsPass fixtureStorePaths;
    assert !fixtureAssertionsPass (fixtureStorePaths ++ [ "accounts/fixture-a/owners/fixture-solo" ]);
    assert !fixtureAssertionsPass (fixtureStorePaths ++ [ "accounts/fixture-c/owners/Fixture-Org" ]);
    assert
      !fixtureOwnersEvaluate (fixtureStorePaths ++ [ "accounts/fixture-b/owners/fixture-nested/team" ]);
    # 導出は Nix の fromJSON、期待値は jq。同じ store を別経路で読んで一致を見る
    pkgs.runCommandLocal "check-account-deployment-contract"
      {
        nativeBuildInputs = [ pkgs.jq ];
        derivedAccounts = lib.concatStringsSep " " accounts;
        derivedPrimary = primary;
        derivedOwners = lib.concatStringsSep " " (
          lib.sort builtins.lessThan (
            lib.concatLists (lib.mapAttrsToList (account: map (owner: "${account}/${owner}")) owners)
          )
        );
      }
      ''
        set -euo pipefail
        test "$(jq -r '.accounts | keys_unsorted | sort | join(" ")' ${storeFile})" = "$derivedAccounts"
        test "$(jq -r '[.accounts | to_entries[] | select(.value | has("primary")) | .key] | join(" ")' ${storeFile})" = "$derivedPrimary"
        test "$(jq -r '[.accounts | to_entries[] | .key as $account | .value.owners // {} | keys_unsorted[] | "\($account)/\(.)"] | sort | join(" ")' ${storeFile})" = "$derivedOwners"
        touch $out
      '';
}
