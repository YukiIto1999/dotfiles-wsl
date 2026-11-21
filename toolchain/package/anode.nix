{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

let
  version = "0.11.4";
  release = "https://github.com/skulitom/Anode/releases/download/v${version}";
in
# Task Scheduler の daemon と子 session の seat host が WSL の停止や Nix の GC より長く同じ path を使うため store 上の anode.exe の直接実行は不可
stdenvNoCC.mkDerivation {
  pname = "anode";
  inherit version;

  src = fetchurl {
    url = "${release}/anode-windows-x64.zip";
    hash = "sha256-xd6khmB5pjUkDkDZve2gu5Ws5Te5Dt6/aDXGaLDo1xE=";
  };
  checksums = fetchurl {
    url = "${release}/SHA256SUMS";
    hash = "sha256-KUHaUsQ+vlm9YPL1KrMolW2tWZpBkyvMlLqJTwsEo84=";
  };

  nativeBuildInputs = [ unzip ];
  dontUnpack = true;

  # install.ps1 が SHA256SUMS を渡された file の名前で照合するため store の hash 付き名での受渡しは不可
  # \\wsl.localhost 越しの Windows PowerShell が symlink を辿れないため symlink による配置は不可
  installPhase = ''
    runHook preInstall
    distribution=$out/share/anode
    install -Dm444 "$src" "$distribution/anode-windows-x64.zip"
    install -Dm444 "$checksums" "$distribution/SHA256SUMS"
    unzip -p "$src" install.ps1 > "$distribution/install.ps1"
    chmod 444 "$distribution/install.ps1"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    (cd "$out/share/anode" && sha256sum --check --strict SHA256SUMS)
    runHook postInstallCheck
  '';

  meta = {
    description = "Background Windows desktop for AI agents - release archive for the offline Windows installer";
    homepage = "https://github.com/skulitom/Anode";
    changelog = "https://github.com/skulitom/Anode/blob/v${version}/CHANGELOG.md";
    license = lib.licenses.mit;
    # WSL が Windows と同じ CPU で動き上流の配布物が x64 専用のため全 platform の宣言は不可
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
