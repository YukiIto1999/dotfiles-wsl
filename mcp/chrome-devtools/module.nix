{
  config,
  lib,
  pkgs,
  mkMcpServer,
  mkNpmMcp,
  serveOverProxy,
  ...
}:

let
  front = pkgs.callPackage ./package.nix {
    inherit mkMcpServer mkNpmMcp;
    inherit (config.my.contract.mcp) chromium;
  };
in
{
  # Playwrightへ統合しない。trace、heap、Lighthouseは別の観測契約を持つため。
  my.mcp.targets.chrome-devtools = {
    port = 8779;
    # chromium が任意の web を開く
    needsNetwork = true;
    serve = serveOverProxy (lib.getExe front);
  };
}
