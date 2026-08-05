{
  config,
  lib,
  pkgs,
  serveOverProxy,
  mkMcpServer,
  mkNpmMcp,
  ...
}:

# self-hosted SearXNG。cache は SQLite で、limiter を使わないので valkey は要らない
let
  mkContainerBackend = import ../../containers/impl/container-backend.nix { inherit lib; };
  frontPort = 8775;
  inherit (config.sops) placeholder;

  port = "8080";
  searxngRepository = "searxng/searxng";
  searxngDigest = "sha256:ec536bcd1e83577aad4cc07f7ecb9a30858a9a905d2d57c8796abc83f872a036";
  searxngImage = "${searxngRepository}:2026.8.1-8892414dc@${searxngDigest}";

  settingsTemplate = pkgs.replaceVars ./assets/settings.yml {
    searxngSecret = placeholder."searxng/secret_key";
    searxngPort = port;
  };

  searxng = mkContainerBackend "searxng" {
    image = searxngImage;
    volumes = [ "/etc/searxng/settings.yml:/etc/searxng/settings.yml:ro" ];
    extraOptions = [ "--memory=512m" ];
    ports = [ port ];
  };

  front = pkgs.callPackage ./package.nix {
    inherit mkMcpServer mkNpmMcp;
    searxngUrl = "http://127.0.0.1:${port}";
  };
in
{
  dotfiles.containers.services.searxng = {
    endpoints.http = {
      protocol = "http";
      address = "127.0.0.1";
      port = 8080;
      url = "http://127.0.0.1:8080";
    };
    units = [ "docker-searxng.service" ];
    images.searxng = {
      kind = "upstream";
      container = "searxng";
      image = searxngImage;
      repository = searxngRepository;
      digest = searxngDigest;
    };
    health = {
      endpoint = "http";
      method = "GET";
      path = "/healthz";
      timeout = 5;
    };
  };

  my.artifacts."mcp/searxng/settings-template" = {
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

  virtualisation.oci-containers.containers = searxng.containers;
  systemd.services = searxng.systemdServices;

  my.mcp.targets.searxng = {
    port = frontPort;
    serve = serveOverProxy (lib.getExe front);
    waitUnits = [ "docker-searxng.service" ];
  };
}
