{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../package/mk-npm.nix { };
  serveOverProxy = pkgs.callPackage ../package/serve-over-proxy.nix { };
  front = pkgs.callPackage ./package.nix {
    inherit mkMcpServer mkNpmMcp;
    inherit (config.dotfiles.mcp) chromium;
  };
in
{
  # Playwrightへ統合しない。trace、heap、Lighthouseは別の観測契約を持つため。
  dotfiles.mcp.targets.chrome-devtools = {
    provider = "chrome-devtools";
    port = 8779;
    # chromium が任意の web を開く
    needsNetwork = true;
    serve = serveOverProxy (lib.getExe front);
    probe = {
      tool = "list_pages";
      args = { };
      timeout = 30;
    };
  };
}
