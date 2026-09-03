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
  accountArtifact = hostConfig.dotfiles.managedArtifacts."accounts/gh-hosts";
  accountTemplate = hostConfig.sops.templates."gh-hosts.yml";
  gitIdentity = hostConfig.dotfiles.toolchain.git.identity;
  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.workstation.username};
  homeDir = hostConfig.dotfiles.workstation.homeDir;
  variantTemplate = variantConfig.sops.templates."gh-hosts.yml";
  noWorkIdentityConfig =
    (mkNixosSystem [
      normalMachineModule
      { dotfiles.toolchain.git.workIdentity = lib.mkForce null; }
    ]).config;
  noWorkIdentityHome =
    noWorkIdentityConfig.home-manager.users.${noWorkIdentityConfig.dotfiles.workstation.username};
  identityDestinationType = hostOptions.dotfiles.toolchain.git.identity.destinations.default.type;
in
{
  account-deployment-contract =
    assert accounts != [ ];
    assert variantConfig.dotfiles.identity.github.accounts == accounts;
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
    pkgs.runCommandLocal "check-account-deployment-contract" { } "touch $out";
}
