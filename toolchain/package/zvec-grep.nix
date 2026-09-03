{
  lib,
  stdenv,
  fetchFromGitHub,
  buildNpmPackage,
  autoPatchelfHook,
}:

buildNpmPackage rec {
  pname = "zvec-grep";
  version = "0.2.1";

  src = fetchFromGitHub {
    owner = "zvec-ai";
    repo = "zvec-grep";
    rev = "v${version}";
    hash = "sha256-8bP+w2YSzWlTJbipmF8ighraZRDye0uiZmd8+Pz4WE8=";
  };

  npmDepsHash = "sha256-pc04qzhnYaS0xpQAYwN6HEG8oPEqoBIBMVKC1OZ0L+8=";
  npmFlags = [ "--ignore-scripts" ];
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  postInstall = ''
    modules=$out/lib/node_modules/@zvec/zvec-grep/node_modules
    rm -rf \
      "$modules/@img/sharp-linuxmusl-x64" \
      "$modules/@img/sharp-libvips-linuxmusl-x64" \
      "$modules/@node-llama-cpp/linux-x64-cuda" \
      "$modules/@node-llama-cpp/linux-x64-cuda-ext" \
      "$modules/@node-llama-cpp/linux-x64-vulkan" \
      "$modules/@reflink/reflink-linux-x64-musl" \
      "$modules/@zvec/bindings-linux-x64-musl"
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
