{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
}:

stdenvNoCC.mkDerivation rec {
  pname = "actrun";
  version = "0.29.0";

  # nixpkgs に無いので upstream の release を固定する
  src = fetchurl {
    url = "https://github.com/mizchi/actrun/releases/download/v${version}/actrun-linux-x64.tar.gz";
    hash = "sha256-B8WPrLKxhJ+7yrUfyvmdLA+NMq9W82jbl5Korx2HOKY=";
  };

  sourceRoot = ".";
  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall
    install -Dm755 actrun $out/bin/actrun
    runHook postInstall
  '';

  meta = {
    description = "GitHub Actions compatible local runner";
    homepage = "https://github.com/mizchi/actrun";
    mainProgram = "actrun";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
