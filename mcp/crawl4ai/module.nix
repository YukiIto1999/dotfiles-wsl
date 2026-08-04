{
  config,
  lib,
  pkgs,
  mkMcpServer,
  serveOverProxy,
  mkContainerBackend,
  ...
}:

let
  port = "11235";
  repository = "unclecode/crawl4ai";
  digest = "sha256:bd36741e7bdd35ddc1a05d9183e1d6d8cefb61dd640d944a25d026b76e917690";
  image = "${repository}:latest@${digest}";

  tokenFile = config.sops.secrets."crawl4ai/api_token".path;

  backend = mkContainerBackend "crawl4ai" {
    inherit image;
    environmentFiles = [ config.sops.templates."crawl4ai.env".path ];
    extraOptions = [
      "--memory=4g"
      "--shm-size=1g"
    ];
    ports = [ port ];
  };

  front = pkgs.callPackage ./package.nix {
    inherit mkMcpServer tokenFile;
    crawl4aiUrl = "http://127.0.0.1:${port}";
  };
in
{
  # front が user として読む。container は env-file 経由なので owner を要さない
  sops.secrets."crawl4ai/api_token".owner = config.my.username;

  # token を渡すと entrypoint が [::] へ bind する。未設定だと loopback bind に
  # 落ちて -p が届かない。config.yml の host は触らない
  sops.templates."crawl4ai.env".content = ''
    CRAWL4AI_API_TOKEN=${config.sops.placeholder."crawl4ai/api_token"}
  '';

  my.images.crawl4ai = {
    kind = "upstream";
    container = "crawl4ai";
    inherit image repository digest;
  };

  virtualisation.oci-containers.containers = backend.containers;
  systemd.services = backend.systemdServices;

  my.mcp.targets.crawl4ai = {
    port = 8773;
    serve = serveOverProxy (lib.getExe front);
    waitUnits = [ "docker-crawl4ai.service" ];
  };
}
