{ config, pkgs, lib, ... }:

# sops-nix: secret declarations and the identity files rendered from them.
# MCP-specific secret files (gateway, searxng, github tokens) live in mcp.nix.

let
  cfg            = config.my;
  userHome       = "/home/${cfg.username}";
  primaryAccount = builtins.head cfg.accounts;
  ph             = config.sops.placeholder;

  userTpl = path: content: {
    inherit path content;
    mode  = "0600";
    owner = cfg.username;
    group = "users";
  };

  render = path: vars: builtins.readFile (pkgs.replaceVars path vars);

  buildGhUser = name: render ../templates/gh-user.yml {
    accountUsername = ph."accounts/${name}/username";
    accountToken    = ph."accounts/${name}/token";
  };

  gitIdentity = render ../home/nixos/.config/git/identity.conf {
    userName  = ph."identity/default/name";
    userEmail = ph."identity/default/email";
  };
  gitWorkIdentity = render ../home/nixos/.config/git/work-identity.conf {
    userName  = ph."identity/work/name";
    userEmail = ph."identity/work/email";
  };
  ghHosts = render ../home/nixos/.config/gh/hosts.yml {
    accountUsers    = lib.concatMapStrings buildGhUser cfg.accounts;
    primaryUsername = ph."accounts/${primaryAccount}/username";
    primaryToken    = ph."accounts/${primaryAccount}/token";
  };
in
{
  sops.defaultSopsFile = ../secrets/secrets.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  sops.secrets = {
    "identity/default/name"  = { };
    "identity/default/email" = { };
    "searxng/secret_key"     = { };
  } // lib.optionalAttrs (cfg.workIdentity != null) {
    "identity/work/name"  = { };
    "identity/work/email" = { };
  } // lib.listToAttrs (lib.concatMap (a: [
    { name = "accounts/${a}/username"; value = { }; }
    # gateway の github wrapper が runtime に cfg.username で読む token file
    { name = "accounts/${a}/token";    value = { owner = cfg.username; }; }
  ]) cfg.accounts);

  sops.templates = {
    "git-identity" = userTpl "${userHome}/.config/git/identity.conf" gitIdentity;
    "gh-hosts.yml" = userTpl "${userHome}/.config/gh/hosts.yml"      ghHosts;
  } // lib.optionalAttrs (cfg.workIdentity != null) {
    "git-work-identity" = userTpl "${userHome}/.config/git/work-identity.conf" gitWorkIdentity;
  };
}
