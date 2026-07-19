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

  buildGhUser =
    name:
    builtins.readFile (
      pkgs.replaceVars ./user.yml {
        accountUsername = placeholder."accounts/${name}/username";
        accountToken = placeholder."accounts/${name}/token";
      }
    );
  ghHostsTemplate = pkgs.replaceVars ./hosts.yml {
    accountUsers = lib.concatMapStrings buildGhUser cfg.accounts;
    primaryUsername = placeholder."accounts/${builtins.head cfg.accounts}/username";
    primaryToken = placeholder."accounts/${builtins.head cfg.accounts}/token";
  };
in
{
  sops.secrets = lib.listToAttrs (
    lib.concatMap (a: [
      {
        name = "accounts/${a}/username";
        value = { };
      }
      # gateway の github wrapper が runtime に cfg.username で読む token file
      {
        name = "accounts/${a}/token";
        value = {
          owner = cfg.username;
        };
      }
    ]) cfg.accounts
  );

  my.configArtifacts = lib.optionalAttrs (cfg.accounts != [ ]) {
    "accounts/gh-hosts" = {
      format = "yaml";
      source = ghHostsTemplate;
    };
  };

  sops.templates = lib.optionalAttrs (cfg.accounts != [ ]) {
    "gh-hosts.yml" = userTpl "${userHome}/.config/gh/hosts.yml" (builtins.readFile ghHostsTemplate);
  };
}
