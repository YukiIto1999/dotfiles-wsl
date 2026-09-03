{
  config,
  lib,
  pkgs,
  ...
}:

let
  agentmemory = pkgs.callPackage ./package.nix {
    agentmemoryUrl = config.dotfiles.platform.containers.services.agentmemory.endpoints.http.url;
    upstreamRoot = config.dotfiles.capabilities.project-memory.agentmemory.upstream.root;
    inherit (config.dotfiles.capabilities.project-memory.agentmemory.upstream) version;
  };
in
{
  options.dotfiles.capabilities.project-memory.agentmemory.clientIntegrations = {
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

  config.dotfiles.capabilities.project-memory.agentmemory.clientIntegrations = {
    inherit (agentmemory) hooks opencodePlugin version;
  };
}
