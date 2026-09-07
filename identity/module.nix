{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles.identity.github;
  accountIdType = lib.types.addCheck lib.types.str (
    value: builtins.match "[a-z0-9]+(-[a-z0-9]+)*" value != null
  );
  inherit (config.dotfiles.workstation) homeDir username;
  inherit (config.sops) placeholder;
  mkUserSecretFile = import ../secrets/sops/impl/user-secret-file.nix { inherit username; };
  gitIdentityContract = config.dotfiles.toolchain.git.identity;

  # git の author identity も、この利用者が誰かという同じ事実。所有を一つにする
  gitIdentity = vars: builtins.readFile (pkgs.replaceVars gitIdentityContract.template vars);

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
    primaryUsername = placeholder."accounts/${cfg.primary}/username";
    primaryToken = placeholder."accounts/${cfg.primary}/token";
  };
in
{
  options.dotfiles.identity.github = {
    accounts = lib.mkOption {
      type = lib.types.listOf accountIdType;
      example = [
        "personal"
        "work"
      ];
      description = "この host が使う GitHub account id。sops secret 対、gh host user、github MCP target に対応する。";
    };
    primary = lib.mkOption {
      type = accountIdType;
      example = "personal";
      description = "gh の active user と hosts.yml の既定 token になる account id。accounts の要素でなければならない。";
    };
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
    // lib.optionalAttrs (config.dotfiles.toolchain.git.workIdentity != null) {
      "identity/work/name" = { };
      "identity/work/email" = { };
    };

  config.dotfiles.managedArtifacts = lib.optionalAttrs (cfg.accounts != [ ]) {
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
      "git-identity" =
        mkUserSecretFile "${homeDir}/${gitIdentityContract.destinations.default}"
          (gitIdentity {
            userName = placeholder."identity/default/name";
            userEmail = placeholder."identity/default/email";
          });
    }
    // lib.optionalAttrs (config.dotfiles.toolchain.git.workIdentity != null) {
      "git-work-identity" =
        mkUserSecretFile "${homeDir}/${gitIdentityContract.destinations.work}"
          (gitIdentity {
            userName = placeholder."identity/work/name";
            userEmail = placeholder."identity/work/email";
          });
    };

  config.assertions = [
    {
      assertion = cfg.accounts != [ ] && cfg.accounts == lib.unique cfg.accounts;
      message = "dotfiles.identity.github.accounts must be non-empty and free of duplicates";
    }
    {
      assertion = builtins.elem cfg.primary cfg.accounts;
      message = "dotfiles.identity.github.primary must be one of dotfiles.identity.github.accounts";
    }
  ];
}
