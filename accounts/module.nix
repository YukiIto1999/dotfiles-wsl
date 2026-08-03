{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.my;
  userHome = cfg.homeDir;
  inherit (config.sops) placeholder;

  userTpl = path: content: {
    inherit path content;
    mode = "0600";
    owner = cfg.username;
    group = "users";
  };

  # git の author identity も、この利用者が誰かという同じ事実。所有を一つにする
  gitIdentity =
    vars: builtins.readFile (pkgs.replaceVars config.my.contract.git.identityTemplate vars);

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
  options.my.accounts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
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
        # github front が起動時に cfg.username で読む token file
        {
          name = "accounts/${a}/token";
          value = {
            owner = cfg.username;
          };
        }
      ]) cfg.accounts
    )
    // {
      "identity/default/name" = { };
      "identity/default/email" = { };
    }
    // lib.optionalAttrs (cfg.git.workIdentity != null) {
      "identity/work/name" = { };
      "identity/work/email" = { };
    };

  config.my.artifacts = lib.optionalAttrs (cfg.accounts != [ ]) {
    "accounts/gh-hosts" = {
      format = "yaml";
      source = ghHostsTemplate;
    };
  };

  config.sops.templates =
    lib.optionalAttrs (cfg.accounts != [ ]) {
      "gh-hosts.yml" = userTpl "${userHome}/.config/gh/hosts.yml" (builtins.readFile ghHostsTemplate);
    }
    // {
      "git-identity" = userTpl "${userHome}/.config/git/identity.conf" (gitIdentity {
        userName = placeholder."identity/default/name";
        userEmail = placeholder."identity/default/email";
      });
    }
    // lib.optionalAttrs (cfg.git.workIdentity != null) {
      "git-work-identity" = userTpl "${userHome}/.config/git/work-identity.conf" (gitIdentity {
        userName = placeholder."identity/work/name";
        userEmail = placeholder."identity/work/email";
      });
    };
}
