{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

stdenv.mkDerivation rec {
  pname = "similarity";
  version = "0.5.0";

  src = fetchurl {
    url = "https://github.com/mizchi/similarity/releases/download/v${version}/similarity-v${version}-x86_64-unknown-linux-gnu.tar.gz";
    hash = "sha256-Kv2mIBtq+x7jbBzlG5WlOOyZMQx59mGQVTbZF0cKQGo=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    for binary in similarity-ts similarity-rs similarity-generic; do
      install -Dm755 "$binary" "$out/bin/$binary"
    done
    install -Dm644 LICENSE "$out/share/licenses/similarity/LICENSE"
    install -Dm644 README.md "$out/share/doc/similarity/README.md"
    runHook postInstall
  '';

  meta = {
    description = "AST-based duplication candidates for TypeScript, Rust and C#";
    homepage = "https://github.com/mizchi/similarity";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "similarity-ts";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
