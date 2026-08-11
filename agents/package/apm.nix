{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  git,
  zlib,
  openssl,
  readline,
  bzip2,
  xz,
  libffi,
  ncurses,
  sqlite,
  libuuid,
}:

stdenvNoCC.mkDerivation rec {
  pname = "apm";
  version = "0.26.0";

  # nixpkgs に無いので upstream の release を固定する
  src = fetchurl {
    url = "https://github.com/microsoft/apm/releases/download/v${version}/apm-linux-x86_64.tar.gz";
    hash = "sha256-OvukVcUoOFK6TDkvZovnwntlvEoPpgqLU6RibFJihDE=";
  };

  sourceRoot = "apm-linux-x86_64";
  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  # PyInstaller が同梱する CPython の拡張 module が要求する共有 library
  buildInputs = [
    zlib
    openssl
    readline
    bzip2
    xz
    libffi
    ncurses
    sqlite
    libuuid
  ];

  # PyInstaller の onedir bundle。実行ファイルは隣の _internal を必要とする
  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/apm $out/bin
    cp -r apm _internal $out/libexec/apm/
    chmod +x $out/libexec/apm/apm
    # 同梱の GitPython が起動時に git を探す
    makeWrapper $out/libexec/apm/apm $out/bin/apm \
      --prefix PATH : ${lib.makeBinPath [ git ]}
    runHook postInstall
  '';

  meta = {
    description = "Agent Package Manager";
    homepage = "https://github.com/microsoft/apm";
    mainProgram = "apm";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
