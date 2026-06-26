{
  lib,
  pkgs,
  mkMcpServer,
  mkMcpBackend,
  ...
}:

let
  uid = "65532";

  httpPort = "3111";
  # stream port は publish しない、engine config 内部専用で consumer なし
  streamPort = "3112";

  agentmemory = pkgs.callPackage ../../../pkgs/agentmemory {
    inherit mkMcpServer;
    agentmemoryUrl = "http://127.0.0.1:${httpPort}";
  };

  agentmemoryConfig = pkgs.replaceVars ./agentmemory.yaml {
    inherit httpPort streamPort;
  };

  backend = mkMcpBackend "agentmemory" {
    image = "${agentmemory.image.imageName}:${agentmemory.image.imageTag}";
    imageFile = agentmemory.image;
    volumes = [
      "${agentmemoryConfig}:/app/config.yaml:ro"
      "/var/lib/agentmemory/data:/data"
    ];
    extraOptions = [ "--user=${uid}:${uid}" ];
    ports = [ httpPort ];
  };
in
{
  systemd.tmpfiles.settings."agentmemory" = {
    "/var/lib/agentmemory/data".d = {
      user = uid;
      group = uid;
      mode = "0755";
    };
  };

  virtualisation.oci-containers.containers = backend.containers;
  systemd.services = backend.systemdServices;

  my.mcp.gatewayWaitUnits = [ "docker-agentmemory.service" ];
  my.mcp.targets.memory.command = lib.getExe agentmemory.front;
}
