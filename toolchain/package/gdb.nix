{
  lib,
  runCommandLocal,
  gdb,
}:

# 起動した子だけを扱う採用範囲のため attach 用の gcore と gstack と遠隔制御用の gdbserver の PATH への配置は不可
runCommandLocal "gdb-${gdb.version}"
  {
    meta = {
      inherit (gdb.meta)
        description
        homepage
        license
        platforms
        ;
      mainProgram = "gdb";
    };
  }
  ''
    mkdir -p "$out/bin" "$out/share"
    ln -s ${lib.getExe gdb} "$out/bin/gdb"
    ln -s ${gdb}/share/man "$out/share/man"
  ''
