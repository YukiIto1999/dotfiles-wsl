{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  autoPatchelfHook,
  icu,
  openssl,
  zlib,
}:

# 組み立ては上流の eng/nix/package.nix（v17.0.0）に合わせる。
# 上流 flake の manifest は release より古い版を指すため、公式 release archive と公開 sha512 を直接固定する
let
  version = "17.0.0";
  libraries = [
    icu
    openssl
    zlib
    stdenv.cc.cc.lib
  ];
in
stdenv.mkDerivation {
  pname = "aspire-cli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/microsoft/aspire/releases/download/v${version}/aspire-cli-linux-x64-${version}.tar.gz";
    hash = "sha512-+SCLUxzDJKhhLR71e8qZFJAUk7QIavjrShgoLEpbazEkbLHOW61R8IqR+xZY1hQ2KHV2aq8DEdg+E2L31E8lOw==";
  };

  # archive は最上位 directory を持たない
  unpackPhase = ''
    runHook preUnpack
    mkdir aspire-cli
    tar -xzf "$src" -C aspire-cli
    cd aspire-cli
    runHook postUnpack
  '';

  nativeBuildInputs = [
    makeWrapper
    autoPatchelfHook
  ];
  buildInputs = libraries;

  dontConfigure = true;
  dontBuild = true;
  # Dashboard 本体は実行ファイルに埋め込まれた bundle で、初回の `dashboard run` が ASPIRE_HOME へ展開する
  dontStrip = true;

  # 上流と同じ sidecar の source=nix により、bundle の展開先は ASPIRE_HOME（既定 ~/.aspire）になる。
  # Microsoft への利用 telemetry と NuGet への update 確認は既定で止め、明示した環境変数を優先する
  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/aspire-cli" "$out/bin"
    cp -R . "$out/lib/aspire-cli/"
    chmod 755 "$out/lib/aspire-cli/aspire"
    printf '%s\n' '{"source":"nix"}' > "$out/lib/aspire-cli/.aspire-install.json"

    makeWrapper "$out/lib/aspire-cli/aspire" "$out/bin/aspire" \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath libraries} \
      --set-default ASPIRE_CLI_TELEMETRY_OPTOUT true \
      --set-default ASPIRE_DASHBOARD_TELEMETRY_OPTOUT true \
      --set-default features__updateNotificationsEnabled false

    runHook postInstall
  '';

  meta = {
    description = "Command line tool for Aspire developers";
    homepage = "https://aspire.dev";
    changelog = "https://github.com/microsoft/aspire/releases/tag/v${version}";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "aspire";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
