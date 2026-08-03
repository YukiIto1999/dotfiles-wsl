{
  pkgs,
  lib,
  mkMcpServer,
  tokenFile,
  toolsets,
}:

# account ごとに 1 instance、PAT は spawn 時に sops file から読む
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
# 1.8.0 は空 token で fail-fast せず対話 OAuth login へ落ちる。sops の復号失敗が
# 起動失敗ではなく tool 実行時のエラーへ後退するので、front 側で落とす
mkMcpServer {
  name = "github-mcp";
  env.GITHUB_PERSONAL_ACCESS_TOKEN = "$(<${tokenFile})";
  command = ''
    ${pkgs.coreutils}/bin/test -s ${tokenFile} \
      && exec ${bin}/bin/github-mcp-server stdio --toolsets ${lib.concatStringsSep "," toolsets}'';
}
