{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles;
  accountIds = [
    "account-1"
    "account-2"
    "account-3"
  ];
  inherit (cfg.host) homeDir username;
  inherit (config.sops) placeholder;
  mkUserSecretFile = import ../sops/impl/user-secret-file.nix { inherit username; };

  # git の author identity も、この利用者が誰かという同じ事実。所有を一つにする
  gitIdentity =
    vars: builtins.readFile (pkgs.replaceVars config.dotfiles.toolchain.git.identityTemplate vars);

  buildGhUser =
    name:
    builtins.readFile (
      pkgs.replaceVars ./assets/user.yml {
        accountUsername = placeholder."accounts/${name}/username";
        accountToken = placeholder."accounts/${name}/token";
      }
    );
  ghHostsTemplate = pkgs.replaceVars ./assets/hosts.yml {
    accountUsers = lib.concatMapStrings buildGhUser cfg.accounts;
    primaryUsername = placeholder."accounts/${builtins.head cfg.accounts}/username";
    primaryToken = placeholder."accounts/${builtins.head cfg.accounts}/token";
  };
in
{
  options.dotfiles.accounts = lib.mkOption {
    type = lib.types.listOf (lib.types.enum accountIds);
    example = [
      "account-1"
      "account-2"
    ];
    description = "GitHub account id。sops secret 対、gh host user、github MCP target に対応する。先頭が primary で、gh の active user と hosts.yml の既定 token になる。";
  };

  config.sops.secrets =
    lib.listToAttrs (
      lib.concatMap (a: [
        {
          name = "accounts/${a}/username";
          value = { };
        }
        # github front が起動時に主 user で読む token file
        {
          name = "accounts/${a}/token";
          value = {
            owner = username;
          };
        }
      ]) cfg.accounts
    )
    // {
      "identity/default/name" = { };
      "identity/default/email" = { };
    }
    // lib.optionalAttrs (cfg.toolchain.git.workIdentity != null) {
      "identity/work/name" = { };
      "identity/work/email" = { };
    };

  config.dotfiles.artifacts = lib.optionalAttrs (cfg.accounts != [ ]) {
    "accounts/gh-hosts" = {
      format = "yaml";
      source = ghHostsTemplate;
    };
  };

  config.sops.templates =
    lib.optionalAttrs (cfg.accounts != [ ]) {
      "gh-hosts.yml" = mkUserSecretFile "${homeDir}/.config/gh/hosts.yml" (
        builtins.readFile ghHostsTemplate
      );
    }
    // {
      "git-identity" = mkUserSecretFile "${homeDir}/.config/git/identity.conf" (gitIdentity {
        userName = placeholder."identity/default/name";
        userEmail = placeholder."identity/default/email";
      });
    }
    // lib.optionalAttrs (cfg.toolchain.git.workIdentity != null) {
      "git-work-identity" = mkUserSecretFile "${homeDir}/.config/git/work-identity.conf" (gitIdentity {
        userName = placeholder."identity/work/name";
        userEmail = placeholder."identity/work/email";
      });
    };

  config.assertions = [
    {
      assertion =
        cfg.accounts != [ ]
        && cfg.accounts == lib.unique cfg.accounts
        && lib.sort builtins.lessThan cfg.accounts == accountIds;
      message = "dotfiles.accounts must contain every supported account exactly once";
    }
  ];
}
