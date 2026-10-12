{
  lib,
  stdenvNoCC,
  fetchurl,
  patchelf,
  glibc,
  zlib,
}:

stdenvNoCC.mkDerivation {
  pname = "strix-native";
  version = "1.7.0";
  src = fetchurl {
    url = "https://github.com/usestrix/strix/releases/download/v1.7.0/strix-1.7.0-linux-x86_64.tar.gz";
    hash = "sha256-uM1+hNY8vv9nJjAangj93t9A/GpO3NtO3aioU7MxLeY=";
  };
  sourceRoot = ".";
  nativeBuildInputs = [ patchelf ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 strix-1.7.0-linux-x86_64 "$out/bin/strix"
    runHook postInstall
  '';
  postFixup = ''
    patchelf \
      --set-interpreter ${glibc}/lib/ld-linux-x86-64.so.2 \
      --set-rpath ${
        lib.makeLibraryPath [
          glibc
          zlib
        ]
      } \
      "$out/bin/strix"
  '';
  meta = {
    description = "Strix security assessment CLI";
    homepage = "https://github.com/usestrix/strix";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strix";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
