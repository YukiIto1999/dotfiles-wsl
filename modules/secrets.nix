{
  config,
  pkgs,
  lib,
  ...
}:

# searxng settings template の secret は modules/mcp/servers/searxng.nix
# github account 関連は modules/accounts.nix

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

  gitIdentity = vars: builtins.readFile (pkgs.replaceVars ./user/git/identity.conf vars);
in
{
  sops.defaultSopsFile = ../secrets/secrets.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.age.generateKey = false;

  systemd.tmpfiles.settings."sops-key" = {
    "/var/lib/sops-nix".d = {
      user = "root";
      group = "root";
      mode = "0700";
    };
    "/var/lib/sops-nix/key.txt".z = {
      user = "root";
      group = "root";
      mode = "0400";
    };
  };

  sops.secrets = {
    "identity/default/name" = { };
    "identity/default/email" = { };
  }
  // lib.optionalAttrs (cfg.workIdentity != null) {
    "identity/work/name" = { };
    "identity/work/email" = { };
  };

  sops.templates = {
    "git-identity" = userTpl "${userHome}/.config/git/identity.conf" (gitIdentity {
      userName = placeholder."identity/default/name";
      userEmail = placeholder."identity/default/email";
    });
  }
  // lib.optionalAttrs (cfg.workIdentity != null) {
    "git-work-identity" = userTpl "${userHome}/.config/git/work-identity.conf" (gitIdentity {
      userName = placeholder."identity/work/name";
      userEmail = placeholder."identity/work/email";
    });
  };
}
