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

    gatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 8765;
      description = "Loopback port the agentgateway MCP listener binds.";
    };

    gatewayUrl = lib.mkOption {
      type = lib.types.str;
      description = "MCP gateway URL every AI CLI points at. Derived from gatewayPort.";
    };

    accounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "account-1" "account-2" ];
      description = "GitHub account ids. Each maps to a sops secret pair, a gh host user and a github MCP target.";
    };

    workIdentity = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "~/projects/business/";
      description = "gitdir glob that selects the work git identity. null disables it.";
    };

    gatewayBackendUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Backend systemd units the gateway waits for. Set by modules/mcp/backends.nix.";
    };
  };

  config.my.gatewayUrl = lib.mkDefault "http://localhost:${toString cfg.gatewayPort}/mcp";
}
