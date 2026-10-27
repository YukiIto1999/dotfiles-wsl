{ lib, cgroupParent }:

name:
{
  image,
  imageFile ? null,
  environmentFiles ? [ ],
  volumes ? [ ],
  extraOptions ? [ ],
  ports ? [ ],
  deps ? [ ],
}:
let
  networkUnit = "docker-dotfiles-backends-network.service";
in
{
  containers."${name}" = {
    inherit image;
    pull = "never";
  }
  // lib.optionalAttrs (imageFile != null) { inherit imageFile; }
  // lib.optionalAttrs (environmentFiles != [ ]) { inherit environmentFiles; }
  // lib.optionalAttrs (volumes != [ ]) { inherit volumes; }
  // {
    # container の PID 1 が application 本体だと、application の終了を shim が回収できず
    # zombie のまま container が running に留まり、systemd の Restart も docker restart も
    # 効かなくなる。init を PID 1 に置いて子を reap し、終了を container の終了へ伝える
    extraOptions = [
      "--init"
      "--network=dotfiles-backends"
      # daemon の既定の slice は宣言済みの backend と上限を分け合うため既定への依存は不可
      "--cgroup-parent=${cgroupParent}"
    ]
    ++ extraOptions
    ++ lib.concatMap (port: [
      "-p"
      "127.0.0.1:${port}:${port}"
    ]) ports;
  };

  systemdServices."docker-${name}" = {
    after = [ networkUnit ] ++ deps;
    requires = [ networkUnit ] ++ deps;
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = "5s";
    };
  };
}
