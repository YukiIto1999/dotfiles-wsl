{ pkgs }:

# nixpkgs 未収録の upstream static-musl release binary
pkgs.stdenvNoCC.mkDerivation rec {
  pname = "agentgateway";
  version = "1.3.1";

  src = pkgs.fetchurl {
    url = "https://github.com/agentgateway/agentgateway/releases/download/v${version}/agentgateway-linux-amd64";
    hash = "sha256-cVMajM2h8J0li0bpJkOnMKATZvtDbhUGLplnLoTNkH8=";
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/agentgateway
    runHook postInstall
  '';

  meta.mainProgram = "agentgateway";
}
