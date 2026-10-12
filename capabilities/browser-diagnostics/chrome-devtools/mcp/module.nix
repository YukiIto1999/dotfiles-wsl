{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  enabled = builtins.elem "browser-diagnostics" config.dotfiles.capabilities.resolved;
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../../../../platform/mcp/package/mk-npm.nix { };
  front = pkgs.callPackage ./package.nix {
    inherit mkNpmMcp;
    src = self.inputs.chromeDevtoolsMcp;
    serverBuilder = mkMcpServer;
    chromium = config.dotfiles.capabilities.browser-runtime.package;
    runtimeDirectoryPath = config.dotfiles.platform.mcp.fronts.chrome-devtools.runtimeDirectoryPath;
  };
in
{
  config = lib.mkIf enabled {
    # 異なる観測契約を持つ trace・heap・Lighthouse の Playwright 統合禁止
    dotfiles.platform.mcp.targets.chrome-devtools = {
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
  };
}
