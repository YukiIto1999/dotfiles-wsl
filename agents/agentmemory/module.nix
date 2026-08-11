{
  config,
  lib,
  pkgs,
  ...
}:

let
  agentmemory = pkgs.callPackage ./package.nix {
    agentmemoryUrl = config.dotfiles.containers.services.agentmemory.endpoints.http.url;
    upstreamRoot = config.dotfiles.containers.agentmemory.upstream.root;
    inherit (config.dotfiles.containers.agentmemory.upstream) version;
  };
in
{
  options.dotfiles.agents.agentmemory = {
    version = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
    };
    hooks = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
    };
    opencodePlugin = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      internal = true;
    };
  };

  config.dotfiles.agents.agentmemory = {
    inherit (agentmemory) hooks opencodePlugin version;
  };
}
