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
    assert lib.hasPrefix "${agentgateway}/bin/agentgateway "
      hostConfig.systemd.services.agentgateway.serviceConfig.ExecStart;
    agentgateway;
}
