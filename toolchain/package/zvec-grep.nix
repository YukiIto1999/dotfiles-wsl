{
  lib,
  stdenv,
  fetchFromGitHub,
  buildNpmPackage,
  autoPatchelfHook,
}:

buildNpmPackage rec {
  pname = "zvec-grep";
  version = "0.2.2";

  src = fetchFromGitHub {
    owner = "zvec-ai";
    repo = "zvec-grep";
    rev = "v${version}";
    hash = "sha256-TDEK7ioPJWShJr5Ch3S6ObwgKqNnP8p9JTWYE2QZ3Z4=";
  };

  npmDepsHash = "sha256-ykSQ5aTt/pgow6GIJAZ6Vo8MqasrLhtKAagHcQgdI4s=";
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
