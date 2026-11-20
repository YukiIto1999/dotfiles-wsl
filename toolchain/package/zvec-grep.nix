{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

stdenv.mkDerivation rec {
  pname = "zvec-grep";
  version = "0.3.1";

  src = fetchurl {
    url = "https://registry.npmjs.org/@zvec/zvec-grep-linux-x64-gnu/-/zvec-grep-linux-x64-gnu-${version}.tgz";
    hash = "sha256-bNqxaSvSDh5Qd5f9ermCRNZ/DsofshVi7m5+zWJFVmU=";
  };
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a bin lib "$out/"
    install -Dm644 LICENSE "$out/share/licenses/zvec-grep/LICENSE"
    install -Dm644 README.md "$out/share/doc/zvec-grep/README.md"
    runHook postInstall
  '';

  meta = {
    description = "Local-first hybrid workspace search for people and AI agents";
    homepage = "https://github.com/zvec-ai/zvec-grep";
    license = lib.licenses.asl20;
    mainProgram = "zg";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
