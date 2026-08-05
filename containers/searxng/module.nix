{
  config,
  lib,
  pkgs,
  ...
}:

# self-hosted SearXNG。cache は SQLite で、limiter を使わないので valkey は要らない
let
  mkContainerBackend = import ../impl/container-backend.nix { inherit lib; };
  inherit (config.sops) placeholder;

  port = "8080";
  repository = "searxng/searxng";
  digest = "sha256:ec536bcd1e83577aad4cc07f7ecb9a30858a9a905d2d57c8796abc83f872a036";
  image = "${repository}:2026.8.1-8892414dc@${digest}";

  settingsTemplate = pkgs.replaceVars ./assets/settings.yml {
    searxngSecret = placeholder."searxng/secret_key";
    searxngPort = port;
  };

  backend = mkContainerBackend "searxng" {
    inherit image;
    volumes = [ "/etc/searxng/settings.yml:/etc/searxng/settings.yml:ro" ];
    extraOptions = [ "--memory=512m" ];
    ports = [ port ];
  };
in
{
  config = {
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
        inherit image repository digest;
      };
      health = {
        endpoint = "http";
        method = "GET";
        path = "/healthz";
        timeout = 5;
      };
    };

    my.artifacts."containers/searxng/settings-template" = {
      format = "yaml";
      source = settingsTemplate;
    };

    sops.secrets."searxng/secret_key" = {
      mode = "0400";
      owner = "root";
      group = "root";
    };

    sops.templates."searxng-settings.yml" = {
      path = "/etc/searxng/settings.yml";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "docker-searxng.service" ];
      content = builtins.readFile settingsTemplate;
    };

    virtualisation.oci-containers.containers = backend.containers;
    systemd.services = backend.systemdServices;
  };
}
