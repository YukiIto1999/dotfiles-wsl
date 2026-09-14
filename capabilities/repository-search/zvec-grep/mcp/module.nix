{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "repository-search" config.dotfiles.capabilities.resolved;
  port = 8784;
  endpoint = "http://127.0.0.1:${toString port}/mcp";
  staleLockPath = "${config.dotfiles.workstation.homeDir}/.zvec-grep/daemon/instance.lock";
  front = pkgs.callPackage ./package.nix {
    zvecGrep = config.dotfiles.toolchain.packages.zvec-grep;
    inherit port;
  };
in
{
  config = lib.mkIf enabled {
    dotfiles.platform.mcp.targets.zvec-grep = {
      provider = "zvec-grep";
      executable = lib.getExe front;
      serverTransport = "streamable-http";
      serverLifecycle = "service";
      inherit port;
      probe = {
        tool = "zvec_grep_search";
        args = {
          root = config.dotfiles.workstation.dotfilesDir;
          fts = [ "dotfiles.platform.mcp.targets" ];
          limit = 1;
          autoUpdate = false;
        };
        timeout = 30;
      };
    };

    # `r` は同一 boot の switch でも走って live lock を消すため、boot 限定の `r!` にする。
    systemd.tmpfiles.settings."zvec-grep".${staleLockPath}."r!" = { };

    home-manager.users.${config.dotfiles.workstation.username}.home.sessionVariables = {
      ZVEC_GREP_MODE = "auto";
      ZVEC_GREP_SERVER_URL = endpoint;
    };
  };
}
