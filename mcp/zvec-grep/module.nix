{
  config,
  lib,
  pkgs,
  ...
}:

let
  port = 8784;
  endpoint = "http://127.0.0.1:${toString port}/mcp";
  front = pkgs.callPackage ./package.nix {
    zvecGrep = config.dotfiles.toolchain.packages.zvec-grep;
    inherit port;
  };
in
{
  dotfiles.mcp.targets.zvec-grep = {
    provider = "zvec-grep";
    executable = lib.getExe front;
    serverTransport = "streamable-http";
    serverLifecycle = "service";
    inherit port;
    probe = {
      tool = "zvec_grep_search";
      args = {
        root = config.dotfiles.host.dotfilesDir;
        fts = [ "dotfiles.mcp.targets" ];
        limit = 1;
        autoUpdate = false;
      };
      timeout = 30;
    };
  };

  home-manager.users.${config.dotfiles.host.username}.home.sessionVariables = {
    ZVEC_GREP_MODE = "auto";
    ZVEC_GREP_SERVER_URL = endpoint;
  };
}
