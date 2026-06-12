{ pkgs, mkMcpServer, tokenFile }:

# account ごとに 1 instance、PAT は spawn 時に sops file から読む
let
  version = "1.0.5";
  bin = pkgs.stdenv.mkDerivation {
    pname   = "github-mcp-server";
    inherit version;
    src = pkgs.fetchurl {
      url  = "https://github.com/github/github-mcp-server/releases/download/v${version}/github-mcp-server_Linux_x86_64.tar.gz";
      hash = "sha256-IBCC9WmoRurv1DGPE7zLXZInws7EUDfR0pLugxERc8E=";
    };
    sourceRoot        = ".";
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    installPhase      = "install -Dm755 github-mcp-server $out/bin/github-mcp-server";
  };
in
mkMcpServer {
  name    = "github-mcp";
  env.GITHUB_PERSONAL_ACCESS_TOKEN = ''$(<${tokenFile})'';
  command = "${bin}/bin/github-mcp-server stdio";
}
