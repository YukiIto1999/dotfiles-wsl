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
  activation ? "boot",
}:
assert lib.assertOneOf "activation" activation [
  "boot"
  "manual"
];
let
  networkUnit = "docker-dotfiles-backends-network.service";
  manual = activation == "manual";
in
{
  containers."${name}" = {
    inherit image;
    pull = "never";
  }
  // lib.optionalAttrs manual { autoStart = false; }
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
  }
  // lib.optionalAttrs manual {
    # 稼働中の backend は operator の停止まで維持する。switch による再起動は処理中の解析を中断するため不可。
    # 新しい定義は次の operator 起動で適用され、それまでの image の相違は doctor が示す
    restartIfChanged = false;
  }
  // {
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = "5s";
    }
    // lib.optionalAttrs manual {
      # 明示停止の docker stop で TERM を受けた application は 128+15 で終わる。
      # 失敗扱いにすると意図した停止が doctor の fault と区別できない
      SuccessExitStatus = "143";
    };
  };
}
