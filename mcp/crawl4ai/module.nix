{
  lib,
  pkgs,
  mkMcpServer,
  mkContainerBackend,
  ...
}:

let
  port = "11235";
  repository = "unclecode/crawl4ai";
  digest = "sha256:a45fd08f8f15f67026c1bff0a151f0479244caf6751a0c6943b3870efafcd025";
  image = "${repository}:latest@${digest}";

  backend = mkContainerBackend "crawl4ai" {
    inherit image;
    extraOptions = [
      "--memory=4g"
      "--shm-size=1g"
    ];
    ports = [ port ];
  };

  front = pkgs.callPackage ./package.nix {
    inherit mkMcpServer;
    crawl4aiUrl = "http://127.0.0.1:${port}";
  };
in
{
  my.ociImages.crawl4ai = {
    kind = "upstream";
    container = "crawl4ai";
    inherit image repository digest;
  };

  virtualisation.oci-containers.containers = backend.containers;
  systemd.services = backend.systemdServices;

  my.mcp.gatewayWaitUnits = [ "docker-crawl4ai.service" ];
  my.mcp.targets.crawl4ai.transport.stdio.command = lib.getExe front;
  my.doctor.units = backend.doctorUnits;
}
