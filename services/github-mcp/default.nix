{ pkgs }:

# GitHub MCP server binary. The gateway spawns "github-mcp-server stdio" per
# account, injecting that account's PAT (see modules/mcp.nix).
let
  version = "1.0.5";
in
pkgs.stdenv.mkDerivation {
  pname   = "github-mcp-server";
  inherit version;

  src = pkgs.fetchurl {
    url  = "https://github.com/github/github-mcp-server/releases/download/v${version}/github-mcp-server_Linux_x86_64.tar.gz";
    hash = "sha256-IBCC9WmoRurv1DGPE7zLXZInws7EUDfR0pLugxERc8E=";
  };

  sourceRoot        = ".";
  nativeBuildInputs = [ pkgs.autoPatchelfHook ];

  installPhase = ''
    runHook preInstall
    install -Dm755 github-mcp-server $out/bin/github-mcp-server
    runHook postInstall
  '';

  meta.mainProgram = "github-mcp-server";
}
