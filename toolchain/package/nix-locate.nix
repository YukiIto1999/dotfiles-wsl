{
  lib,
  fetchurl,
  linkFarm,
  runCommandLocal,
  makeBinaryWrapper,
  nix-index-unwrapped,
}:

let
  # 週次で差し替わる上流の最新 release を追うと結果が評価時期で変わるため latest の参照は不可
  release = "2026-11-15-095805";

  database =
    (fetchurl {
      url = "https://github.com/nix-community/nix-index-database/releases/download/${release}/index-x86_64-linux-stable-small";
      hash = "sha256-OyM2DeFTdsRLQqwgcRvQsgEM8RTPMmJdL1EoHlRwMXM=";
    }).overrideAttrs
      {
        # DB が列挙する store path を参照として検出するため fixed-output の参照走査は不可
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      };
in
# 端末での index 生成は network と時間を要し結果が実行時期で変わるため nix-index の配備は不可
runCommandLocal "nix-locate-${nix-index-unwrapped.version}"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    meta = {
      description = "nix-locate over the pinned nix-index-database stable-small index";
      homepage = "https://github.com/nix-community/nix-index-database";
      inherit (nix-index-unwrapped.meta) license;
      mainProgram = "nix-locate";
      platforms = [ "x86_64-linux" ];
    };
  }
  ''
    makeWrapper ${lib.getExe' nix-index-unwrapped "nix-locate"} "$out/bin/nix-locate" \
      --set NIX_INDEX_DATABASE ${linkFarm "nix-index-database" { files = database; }}
  ''
