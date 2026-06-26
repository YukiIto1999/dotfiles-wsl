{
  lib,
  pkgs,
  mkMcpServer,
  mkMcpBackend,
  ...
}:

let
  port = "11235";

  backend = mkMcpBackend "crawl4ai" {
    image = "unclecode/crawl4ai:latest@sha256:a45fd08f8f15f67026c1bff0a151f0479244caf6751a0c6943b3870efafcd025";
    extraOptions = [
      "--memory=2g"
      "--shm-size=1g"
    ];
    ports = [ port ];
  };

  front = pkgs.callPackage ../../../pkgs/crawl4ai-mcp {
    inherit mkMcpServer;
    crawl4aiUrl = "http://127.0.0.1:${port}";
  };
in
{
  virtualisation.oci-containers.containers = backend.containers;
  systemd.services = backend.systemdServices;

  my.mcp.gatewayWaitUnits = [ "docker-crawl4ai.service" ];
  my.mcp.targets.crawl4ai.command = lib.getExe front;
}
