{
  config,
  lib,
  pkgs,
  mkMcpServer,
  mkNpmMcp,
  mkContainerBackend,
  ...
}:

# self-hosted SearXNG。cache は SQLite で、limiter を使わないので valkey は要らない
let
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
  # 検査は port を転記せずここを読む
  my.contract.searxng.port = port;
  my.images = {
    searxng = {
      kind = "upstream";
      container = "searxng";
      image = searxngImage;
      repository = searxngRepository;
      digest = searxngDigest;
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

  # listen 先を環境変数でしか受けないので、env 経由でも ExecStart に現れる形で渡す
  my.mcp.targets.searxng = {
    port = frontPort;
    serve =
      listenPort:
      "${pkgs.coreutils}/bin/env MCP_HTTP_HOST=127.0.0.1 MCP_HTTP_PORT=${toString listenPort} ${lib.getExe front}";
    waitUnits = [ "docker-searxng.service" ];
  };
  my.doctor.units = searxng.doctorUnits;
}
