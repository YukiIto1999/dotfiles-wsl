{
  pkgs,
  lib,
  tokenFile,
  toolsets,
  serverBuilder,
}:

let
  version = "1.14.0";
  bin = pkgs.stdenv.mkDerivation {
    pname = "github-mcp-server";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://github.com/github/github-mcp-server/releases/download/v${version}/github-mcp-server_Linux_x86_64.tar.gz";
      hash = "sha256-L8rVa7FktsSRj92fHVVyJXv04fFLfrERnQFbB5gY/Tg=";
    };
    sourceRoot = ".";
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    installPhase = "install -Dm755 github-mcp-server $out/bin/github-mcp-server";
  };
in
serverBuilder {
  name = "github-mcp";
  requireNonEmpty = [ tokenFile ];
  env.GITHUB_PERSONAL_ACCESS_TOKEN = "$(<${tokenFile})";
  command = "${bin}/bin/github-mcp-server stdio --toolsets ${lib.concatStringsSep "," toolsets}";
}
