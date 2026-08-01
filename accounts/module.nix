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

  config.sops.secrets = lib.listToAttrs (
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
  );

  config.my.artifacts = lib.optionalAttrs (cfg.accounts != [ ]) {
    "accounts/gh-hosts" = {
      format = "yaml";
      source = ghHostsTemplate;
    };
  };

  config.sops.templates = lib.optionalAttrs (cfg.accounts != [ ]) {
    "gh-hosts.yml" = userTpl "${userHome}/.config/gh/hosts.yml" (builtins.readFile ghHostsTemplate);
  };
}
