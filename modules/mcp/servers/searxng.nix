{
  config,
  lib,
  pkgs,
  mkMcpServer,
  mkNpmMcp,
  mkMcpBackend,
  ...
}:

# self-hosted SearXNG、valkey は cache 実装詳細としてここに同居
let
  inherit (config.sops) placeholder;

  port = "8080";
  valkeyPort = "6379";

  settings = builtins.readFile (
    pkgs.replaceVars ./searxng-settings.yml {
      searxngSecret = placeholder."searxng/secret_key";
      searxngPort = port;
      inherit valkeyPort;
    }
  );

  valkey = mkMcpBackend "valkey" {
    image = "valkey/valkey:latest@sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9";
    extraOptions = [ "--memory=128m" ];
  };

  searxng = mkMcpBackend "searxng" {
    image = "searxng/searxng:2026.5.17-d7e8b7cd1@sha256:25ff3c045548971d12726e54bea4564b8ec3bedb3d6951aecdefd01caf840974";
    volumes = [ "/etc/searxng/settings.yml:/etc/searxng/settings.yml:ro" ];
    extraOptions = [ "--memory=512m" ];
    ports = [ port ];
    deps = [ "docker-valkey.service" ];
  };

  front = pkgs.callPackage ../../../pkgs/searxng-mcp {
    inherit mkMcpServer mkNpmMcp;
    searxngUrl = "http://127.0.0.1:${port}";
  };
in
{
  sops.secrets."searxng/secret_key" = { };

  sops.templates."searxng-settings.yml" = {
    path = "/etc/searxng/settings.yml";
    mode = "0400";
    owner = "root";
    group = "root";
    restartUnits = [ "docker-searxng.service" ];
    content = settings;
  };

  virtualisation.oci-containers.containers = valkey.containers // searxng.containers;
  systemd.services = valkey.systemdServices // searxng.systemdServices;

  my.mcp.gatewayWaitUnits = [ "docker-searxng.service" ];
  my.mcp.targets.searxng.command = lib.getExe front;
}
