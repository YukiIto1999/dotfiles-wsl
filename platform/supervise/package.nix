/**
  source 検査からも利用できる子孫回収 command の構築
  lib: 実行 file の解決に用いる Nixpkgs library
  python3: supervisor を動かす固定済み interpreter
  writeShellApplication: 実行入口を生成する Nixpkgs builder
  戻り値: 子孫回収 command を公開する package
*/
{
  lib,
  python3,
  writeShellApplication,
}:

writeShellApplication {
  name = "dotfiles-supervise";
  text = ''
    exec ${lib.getExe python3} -I -S ${./impl/supervise.py} "$@"
  '';
}
