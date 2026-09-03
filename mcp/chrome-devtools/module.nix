{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../package/mk-npm.nix { };
  front = pkgs.callPackage ./package.nix {
    inherit mkNpmMcp;
    serverBuilder = mkMcpServer;
    inherit (config.dotfiles.mcp) chromium;
  };
in
{
  # 異なる観測契約を持つ trace・heap・Lighthouse の Playwright 統合禁止
  dotfiles.mcp.targets.chrome-devtools = {
    provider = "chrome-devtools";
    executable = lib.getExe front;
    serverLifecycle = "session";
    port = 8779;
    needsNetwork = true;
    probe = {
      tool = "list_pages";
      args = { };
      timeout = 30;
    };
  };
}
