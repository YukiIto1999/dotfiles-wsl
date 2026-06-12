{ pkgs }:

# agentgateway: upstream static-musl release binary (not in nixpkgs).
pkgs.stdenvNoCC.mkDerivation rec {
  pname   = "agentgateway";
  version = "1.2.1";

  src = pkgs.fetchurl {
    url  = "https://github.com/agentgateway/agentgateway/releases/download/v${version}/agentgateway-linux-amd64";
    hash = "sha256-kPVJx/bOk9ZbamcIyar6yPk14wRdPQNXZvcTvIUMPDo=";
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/agentgateway
    runHook postInstall
  '';

  meta.mainProgram = "agentgateway";
}
