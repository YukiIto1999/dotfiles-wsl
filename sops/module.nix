{
  pkgs,
  ...
}:

{
  config.sops.defaultSopsFile = ../secrets/secrets.yaml;
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
}
