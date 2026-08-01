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
  valkeyRepository = "valkey/valkey";
  valkeyDigest = "sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9";
  valkeyImage = "${valkeyRepository}:latest@${valkeyDigest}";
  searxngRepository = "searxng/searxng";
  searxngDigest = "sha256:25ff3c045548971d12726e54bea4564b8ec3bedb3d6951aecdefd01caf840974";
  searxngImage = "${searxngRepository}:2026.5.17-d7e8b7cd1@${searxngDigest}";

  settingsTemplate = pkgs.replaceVars ./assets/settings.yml {
    searxngSecret = placeholder."searxng/secret_key";
    searxngPort = port;
    inherit valkeyPort;
  };

  valkey = mkMcpBackend "valkey" {
    image = valkeyImage;
    extraOptions = [ "--memory=128m" ];
  };

  searxng = mkMcpBackend "searxng" {
    image = searxngImage;
    volumes = [ "/etc/searxng/settings.yml:/etc/searxng/settings.yml:ro" ];
    extraOptions = [ "--memory=512m" ];
    ports = [ port ];
    deps = [ "docker-valkey.service" ];
  };

  front = pkgs.callPackage ./package.nix {
    inherit mkMcpServer mkNpmMcp;
    searxngUrl = "http://127.0.0.1:${port}";
  };
in
{
  my.ociImages = {
    valkey = {
      kind = "upstream";
      container = "valkey";
      image = valkeyImage;
      repository = valkeyRepository;
      digest = valkeyDigest;
    };
    searxng = {
      kind = "upstream";
      container = "searxng";
      image = searxngImage;
      repository = searxngRepository;
      digest = searxngDigest;
    };
  };

  my.configArtifacts."mcp/searxng/settings-template" = {
    format = "yaml";
    source = settingsTemplate;
  };

  sops.secrets."searxng/secret_key" = { };

  sops.templates."searxng-settings.yml" = {
    path = "/etc/searxng/settings.yml";
    mode = "0400";
    owner = "root";
    group = "root";
    restartUnits = [ "docker-searxng.service" ];
    content = builtins.readFile settingsTemplate;
  };

  virtualisation.oci-containers.containers = valkey.containers // searxng.containers;
  systemd.services = valkey.systemdServices // searxng.systemdServices;

  my.mcp.gatewayWaitUnits = [ "docker-searxng.service" ];
  my.mcp.targets.searxng.command = lib.getExe front;
  my.doctor.units = valkey.doctorUnits // searxng.doctorUnits;
}
