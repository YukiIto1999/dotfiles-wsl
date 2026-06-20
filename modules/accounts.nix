{ config, pkgs, lib, ... }:

let
  cfg         = config.my;
  userHome    = cfg.homeDir;
  placeholder = config.sops.placeholder;

  userTpl = path: content: {
    inherit path content;
    mode  = "0600";
    owner = cfg.username;
    group = "users";
  };

  buildGhUser = name: builtins.readFile (pkgs.replaceVars ./gh-user.yml {
    accountUsername = placeholder."accounts/${name}/username";
    accountToken    = placeholder."accounts/${name}/token";
  });
in
{
  sops.secrets = lib.listToAttrs (lib.concatMap (a: [
    { name = "accounts/${a}/username"; value = { }; }
    # gateway の github wrapper が runtime に cfg.username で読む token file
    { name = "accounts/${a}/token";    value = { owner = cfg.username; }; }
  ]) cfg.accounts);

  sops.templates = lib.optionalAttrs (cfg.accounts != [ ]) (
    let
      primaryAccount = builtins.head cfg.accounts;
      ghHosts = builtins.readFile (pkgs.replaceVars ../home/nixos/.config/gh/hosts.yml {
        accountUsers    = lib.concatMapStrings buildGhUser cfg.accounts;
        primaryUsername = placeholder."accounts/${primaryAccount}/username";
        primaryToken    = placeholder."accounts/${primaryAccount}/token";
      });
    in
    {
      "gh-hosts.yml" = userTpl "${userHome}/.config/gh/hosts.yml" ghHosts;
    }
  );
}
