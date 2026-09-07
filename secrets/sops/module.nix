{
  config,
  lib,
  pkgs,
  ...
}:

let
  store = ./assets/secrets.json;
  # sops は値だけを暗号化し、key の構造は平文で残す。どの secret が登録済みかは
  # この構造が正本であり、宣言側へ写さずここから導出する
  flattenPaths =
    prefix: value:
    if builtins.isAttrs value then
      lib.concatMap (name: flattenPaths (prefix ++ [ name ]) value.${name}) (builtins.attrNames value)
    else
      [ (lib.concatStringsSep "/" prefix) ];
  storePaths = lib.sort builtins.lessThan (
    flattenPaths [ ] (builtins.removeAttrs (builtins.fromJSON (builtins.readFile store)) [ "sops" ])
  );
  secretObservations = lib.mapAttrs' (
    id: secret:
    lib.nameValuePair "sops/${id}" {
      kind = "path-metadata";
      checkId = "secret/${id}";
      resourceKey = null;
      timeoutSeconds = 10;
      failureMessage = "${secret.path} metadata does not match the declared secret metadata";
      inherit (secret) path mode;
      owner = if secret.owner == null then "root" else secret.owner;
      group = if secret.group == null then "root" else secret.group;
    }
  ) config.sops.secrets;
in
{
  options.dotfiles.secrets.paths = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    internal = true;
    description = "暗号化済み store が持つ secret path の一覧。値は保持しない。";
  };

  config.dotfiles.secrets.paths = storePaths;

  config.sops.defaultSopsFile = store;
  config.sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  config.sops.age.generateKey = false;

  # 鍵は root だけが読む。tmpfiles が mode を毎回そろえる
  config.systemd.tmpfiles.settings."sops-key" = {
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

  # 利用者が secret を編集するための実行ファイル
  config.environment.systemPackages = with pkgs; [
    sops
    age
  ];

  config.dotfiles.health.observations = secretObservations;
}
