{ config, lib, ... }:

let
  cfg = config.my;
in
{
  options.my = {
    username = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "Primary login user and WSL default user.";
    };

    homeDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Primary user's home directory. Derived from username.";
    };

    dotfilesDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.homeDir}/dotfiles-wsl";
      description = "Absolute path to the dotfiles checkout that out-of-store symlinks and scripts reference.";
    };

    gatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 8765;
      description = "Loopback port the agentgateway MCP listener binds.";
    };

    gatewayUrl = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "MCP gateway URL every AI CLI points at. Derived from gatewayPort.";
    };

    accounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "account-1"
        "account-2"
      ];
      description = "GitHub account ids. Each maps to a sops secret pair, a gh host user and a github MCP target. The first entry is primary: gh's active user and the default token in hosts.yml.";
    };

    workIdentity = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "~/projects/business/";
      description = "gitdir glob that selects the work git identity. null disables it.";
    };
  };

  config.my = {
    homeDir = "/home/${cfg.username}";
    gatewayUrl = "http://localhost:${toString cfg.gatewayPort}/mcp";
  };
}
