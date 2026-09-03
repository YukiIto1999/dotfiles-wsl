{
  config,
  lib,
  ...
}:

let
  mkContainerBackend = import ../../../../platform/containers/impl/container-backend.nix {
    inherit lib;
  };
  port = "11235";
  repository = "unclecode/crawl4ai";
  digest = "sha256:bd36741e7bdd35ddc1a05d9183e1d6d8cefb61dd640d944a25d026b76e917690";
  image = "${repository}:latest@${digest}";

  backend = mkContainerBackend "crawl4ai" {
    inherit image;
    environmentFiles = [ config.sops.templates."crawl4ai.env".path ];
    extraOptions = [
      "--memory=4g"
      "--shm-size=1g"
    ];
    ports = [ port ];
  };
in
{
  options.dotfiles.capabilities.web-content.crawl4ai.credentials.apiTokenFile = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
  };

  config = {
    dotfiles.capabilities.web-content.crawl4ai.credentials.apiTokenFile =
      config.sops.secrets."crawl4ai/api_token".path;

    dotfiles.platform.containers.services.crawl4ai = {
      endpoints.http = {
        protocol = "http";
        address = "127.0.0.1";
        port = 11235;
        url = "http://127.0.0.1:11235";
      };
      units = [ "docker-crawl4ai.service" ];
      containerPolicy.secretReaders."crawl4ai.env" = [ "crawl4ai" ];
      images.crawl4ai = {
        kind = "upstream";
        container = "crawl4ai";
        inherit image repository digest;
      };
      health = {
        endpoint = "http";
        method = "GET";
        path = "/health";
        timeout = 5;
      };
    };

    # front が user として読む。container は root の env-file 経由で読む
    sops.secrets."crawl4ai/api_token" = {
      mode = "0400";
      owner = config.dotfiles.workstation.username;
      group = "users";
    };

    # token を渡すと entrypoint が [::] へ bind する。未設定では container 内の
    # loopback bind に落ち、host の loopback publish から到達できない
    sops.templates."crawl4ai.env" = {
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "docker-crawl4ai.service" ];
      content = ''
        CRAWL4AI_API_TOKEN=${config.sops.placeholder."crawl4ai/api_token"}
      '';
    };

    virtualisation.oci-containers.containers = backend.containers;
    systemd.services = backend.systemdServices;
  };
}
