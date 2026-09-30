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
  # GitHub の user 名と organization 名。URL の path と Git 設定の subsection へそのまま入る
  ownerType = lib.types.addCheck lib.types.str (
    value: builtins.match "[A-Za-z0-9]+(-[A-Za-z0-9]+)*" value != null
  );
  # 誰が登録済みかは暗号化済み store の key 構造が持つ。宣言側へ id を書かない
  accountOf = path: builtins.elemAt (lib.splitString "/" path) 1;
  accountPaths = builtins.filter (path: lib.hasPrefix "accounts/" path) config.dotfiles.secrets.paths;
  storeAccounts = lib.unique (map accountOf accountPaths);
  # account 直下の key だけを印として読む。primary という名前の owner を印と取り違えない
  storePrimaries = builtins.filter (
    account: builtins.elem "accounts/${account}/primary" accountPaths
  ) storeAccounts;
  # accounts/<id>/owners/<owner> の key は、その owner の repository へ HTTPS で接続する account の印
  ownersOf =
    account:
    let
      prefix = "accounts/${account}/owners/";
    in
    map (lib.removePrefix prefix) (builtins.filter (lib.hasPrefix prefix) accountPaths);
  storeOwners = lib.genAttrs storeAccounts ownersOf;
  # GitHub は owner 名の大文字と小文字を区別しない。表記が違っても同じ owner として数える
  ownerKeys = map lib.toLower (lib.concatLists (builtins.attrValues storeOwners));
  duplicatedOwners = lib.unique (
    builtins.filter (owner: lib.count (key: key == owner) ownerKeys > 1) ownerKeys
  );
  # primary の repository は gh の既定 token で届く。印は既定と異なる account を選ぶためだけに置く
  primaryOwners = lib.concatMap ownersOf storePrimaries;
  accountsMissingCredentials = builtins.filter (
    account:
    !(
      builtins.elem "accounts/${account}/username" accountPaths
      && builtins.elem "accounts/${account}/token" accountPaths
    )
  ) storeAccounts;
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
      readOnly = true;
      internal = true;
      description = "暗号化済み store から導出した GitHub account id。gh host user と github MCP target に対応する。";
    };
    primary = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "store が primary と印を付けた account id。gh の active user と hosts.yml の既定 token になる。";
    };
    owners = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf ownerType);
      readOnly = true;
      internal = true;
      description = "store が account ごとに印を付けた GitHub owner。その owner の repository へ HTTPS で接続するときに、この account の token を使う。primary は印を持たず gh の既定 token を使う。";
    };
  };

  config.dotfiles.identity.github = {
    accounts = storeAccounts;
    primary = if builtins.length storePrimaries == 1 then builtins.head storePrimaries else "";
    owners = storeOwners;
  };

  config.sops.secrets =
    lib.listToAttrs (
      lib.concatMap (a: [
        {
          name = "accounts/${a}/username";
          value = { };
        }
        # github front と Git の credential helper が主 user で読む token file
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
      assertion = storeAccounts != [ ];
      message = "the encrypted store must declare at least one entry under accounts/";
    }
    {
      assertion = builtins.length storePrimaries == 1;
      message = "exactly one account in the encrypted store must carry a primary marker, found ${toString (builtins.length storePrimaries)}";
    }
    {
      assertion = accountsMissingCredentials == [ ];
      message = "accounts in the encrypted store must hold both username and token: ${lib.concatStringsSep ", " accountsMissingCredentials}";
    }
    {
      assertion = duplicatedOwners == [ ];
      message = "a GitHub owner in the encrypted store must be marked on exactly one account: ${lib.concatStringsSep ", " duplicatedOwners}";
    }
    {
      assertion = primaryOwners == [ ];
      message = "the primary account reaches its owners through gh and must not carry owner markers: ${lib.concatStringsSep ", " primaryOwners}";
    }
  ];
}
