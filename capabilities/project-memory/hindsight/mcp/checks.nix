{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  runtime = hostConfig.dotfiles.capabilities.project-memory.runtime;
  front = pkgs.callPackage ./package.nix {
    serverBuilder = mkMcpServer;
    inherit runtime;
  };
  target = hostConfig.dotfiles.platform.mcp.targets.memory;
in
{
  hindsight-front =
    assert target.serverLifecycle == "service";
    assert target.port == 8774;
    assert target.waitUnits == [ "docker-hindsight.service" ];
    assert target.probe.tool == "memory_health";
    pkgs.runCommandLocal "check-hindsight-front" { } ''
      ${runtime.python}/bin/python ${./checks/front.py} ${lib.getExe front}
      touch "$out"
    '';
}
