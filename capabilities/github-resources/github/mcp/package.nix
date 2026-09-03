{
  pkgs,
  lib,
  tokenFile,
  toolsets,
  serverBuilder,
}:

let
  version = "1.8.0";
  bin = pkgs.stdenv.mkDerivation {
    pname = "github-mcp-server";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://github.com/github/github-mcp-server/releases/download/v${version}/github-mcp-server_Linux_x86_64.tar.gz";
      hash = "sha256-snVJIa7BsTArGacVMdJtJC7w5/HgVpa4REvqtafmHVs=";
    };
    sourceRoot = ".";
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    installPhase = "install -Dm755 github-mcp-server $out/bin/github-mcp-server";
  };
in
serverBuilder {
  name = "github-mcp";
  # 空トークンを対話 OAuth と解釈する github-mcp-server 1.8.0 の仕様
  requireNonEmpty = [ tokenFile ];
  env.GITHUB_PERSONAL_ACCESS_TOKEN = "$(<${tokenFile})";
  command = "${bin}/bin/github-mcp-server stdio --toolsets ${lib.concatStringsSep "," toolsets}";
}
