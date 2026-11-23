# 公開された commit の archive を取得し、host が固定した検査器で隔離した build の中で検査する。
# 評価するのはこの file だけで、取得した source の Nix code は評価しない。
# 出力は revision と source への symlink だけを持ち、その参照が source を GC から保護する
{
  validator,
  archive,
  revision,
}:
derivation {
  name = "standard-package-validation";
  system = builtins.currentSystem;
  builder = "${builtins.storePath validator}/bin/dotfiles-standard-package-validate";
  args = [
    (builtins.fetchTarball {
      name = "source";
      url = archive;
    })
    revision
  ];
  # 検査結果は手元の build だけで作り、substituter が配る結果を受け入れない
  allowSubstitutes = false;
  preferLocalBuild = true;
}
