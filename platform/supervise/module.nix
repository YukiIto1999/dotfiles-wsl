{
  lib,
  pkgs,
  ...
}:

let
  supervise = pkgs.writeShellApplication {
    name = "dotfiles-supervise";
    text = ''
      exec ${lib.getExe pkgs.python3} -I -S ${./impl/supervise.py} "$@"
    '';
  };
in
{
  options.dotfiles.platform.supervise.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    description = ''
      絶対pathのcommandを一度だけ起動し、その子孫の終了をkernelの観測（waitpidのECHILD）で確認してから返す。
      `dotfiles-supervise [--term-grace SEC] [--kill-grace SEC] [--result FILE] [--argv0 NAME] [--hold-fd N] [--parent-death-cancels PID] -- COMMAND...`の形で呼ぶ。
      SIGTERMとSIGHUPはsession全体の取消とし、SIGINTとSIGQUITはsession全体の取消として扱わない。
      commandの終了または取消で終了処理を始め、所有する全processへSIGTERM、猶予、SIGKILLの順に送る。
      commandの終了status（signalは128+n）を保つが、SIGKILL後も所有processが残る場合は70、起動できない場合は126か127、使い方が不正な場合は2を返す。
      `--result`のJSONはstartedとfinishedの段階、client_status、drained、remainingを持つ。
      `--argv0`は起動するfileを変えず、そのfileが受け取るargv[0]だけを替える。
      `--hold-fd`のdescriptorはcommandと子孫へ渡さず、全processの終了確認までsupervisorが保持する。
      終了を確認できなければ、切り離したholderが残存processの終了までdescriptorを保持する。
      `--parent-death-cancels`には呼び出し側自身のPIDを渡し、その親を失った場合は起動準備前の終了も含めて取消とする。
      指定しなければsessionは呼び出し側より長く生きる。
    '';
  };

  config.dotfiles.platform.supervise.package = supervise;
}
