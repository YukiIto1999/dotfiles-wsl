{
  writeShellApplication,
  aspireCli,
  coreutils,
  curl,
  git,
  python3,
  util-linux,
}:

# 必要時だけ前景で起動する。常駐 service、AppHost、container は持たない
writeShellApplication {
  name = "aspire-dashboard";
  runtimeInputs = [
    aspireCli
    coreutils
    curl
    git
    python3
    util-linux
  ];
  text = builtins.readFile ./aspire-dashboard.sh;
}
