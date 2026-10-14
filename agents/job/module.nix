{
  config,
  lib,
  pkgs,
  ...
}:

let
  runner = pkgs.writeShellApplication {
    name = "dotfiles-agent-job";
    text = ''
      exec ${lib.getExe pkgs.python3} ${./package/runner.py} "$@"
    '';
  };
in
{
  options.dotfiles.agents.job.mk = lib.mkOption {
    type = lib.types.raw;
    readOnly = true;
    internal = true;
    description = "非対話 job を組み立てる関数。`{ name; description; worker; onCalendar; executionDependencies; executables; }` から、manual command の wrapper、user service と timer の宣言、user manager を読む observation を返す。`executables` は worker の option 名から、worker が model を呼ぶ profile 上の実行 path への対応で、runner が`--executable <option名>=<path>`として受け取る。runner は worker の引数に利用者が明示した`--<option名>`の値を含めた実効の実行 path だけを GC root に取り、保護した物理 path を`--<option名>`一つとして worker へ渡す。略記した option は拒否する。manual と timer は同じ job entry を呼び、排他、6時間の絶対期限、実行依存の保護を runner が、保護の command と worker の子孫の回収を共通の supervisor が与える。";
  };

  config.dotfiles.agents.job.mk = import ./impl/mk-job.nix {
    inherit lib pkgs runner;
    inherit (config.dotfiles.agents) lifecycle;
  };
}
