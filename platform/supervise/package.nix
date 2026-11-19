/**
  source 検査からも利用できる子孫回収 command の構築
  lib: 実行 file の解決に用いる Nixpkgs library
  python3: supervisor を動かす固定済み interpreter
  writeShellApplication: 実行入口を生成する Nixpkgs builder
  writeText: 検査用 policy を書く Nixpkgs builder
  戻り値: 子孫回収 command を公開する package。passthru の sandboxPolicy は、user manager も cgroup も無い sandbox で
    同じ supervisor へ渡す policy を作る関数で、systemd-run と systemctl の代わりに cgroup の木を directory に持つ代替を使う
*/
{
  lib,
  python3,
  writeShellApplication,
  writeText,
}:

let
  supervise = writeShellApplication {
    name = "dotfiles-supervise";
    text = ''
      exec ${lib.getExe python3} -I -S ${./impl}/supervise.py "$@"
    '';
  };
  fakeSystemd = ./fixtures/fake_systemd.py;
in
supervise.overrideAttrs (previous: {
  passthru = (previous.passthru or { }) // {
    sandboxPolicy =
      {
        class,
        runtimeDirectory,
        cgroupRoot,
        observation,
        memoryPercent ? 2,
        maximumObservationAgeSeconds ? 10,
        # 計測の一行を受ける journald の代わりの socket。省けば既定の journald の socket で、sandbox には無く送れない
        journalSocket ? null,
        # capped の policy が持つ、capped の走行が合わせて予約できる CPU の割合（CPU一つ分が100）。capped の policy では必須で、他の class は省く
        cpuBudgetPercent ? null,
      }:
      let
        fake = mode: [
          (lib.getExe python3)
          fakeSystemd
          "--cgroup-root"
          cgroupRoot
          mode
        ];
      in
      writeText "sandbox-workload-policy-${class}.json" (
        builtins.toJSON (
          {
            inherit
              class
              runtimeDirectory
              cgroupRoot
              observation
              memoryPercent
              maximumObservationAgeSeconds
              ;
            systemdRun = fake "run";
            systemctl = fake "ctl";
            slices = {
              acceptance = "agents.slice/agents-acceptance.slice";
              deep = "agents.slice/agents-deep.slice";
              capped = "agents.slice/agents-capped.slice";
            };
            # sandbox の観測が返す outcome は一つで、全 class の入場を止める guest の値の代わり。圧迫は持たない
            guestOutcomeIds = [ "resource/fixture" ];
            pressureOutcomeIds = [ ];
          }
          // lib.optionalAttrs (journalSocket != null) { inherit journalSocket; }
          // lib.optionalAttrs (cpuBudgetPercent != null) { inherit cpuBudgetPercent; }
        )
      );
  };
})
