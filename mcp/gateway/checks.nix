{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  agentgateway = pkgs.callPackage ./package.nix { };
in
{
  # 配備する package そのものを build し、同梱の downstream lifecycle test を実行する
  agentgateway-session-lifecycle =
    assert lib.all (
      endpoint:
      hostConfig.systemd.services."${endpoint.service}".serviceConfig.ExecStart
      == "${agentgateway}/bin/agentgateway -f ${endpoint.source}"
    ) (builtins.attrValues hostConfig.my.contract.mcp.endpoints);
    agentgateway;
}
