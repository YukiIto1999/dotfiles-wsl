{
  config,
  lib,
  pkgs,
  mkMcpServer,
  mkNpmMcp,
  mkContainerBackend,
  ...
}:

# self-hosted SearXNG、valkey は cache 実装詳細としてここに同居
let
  frontPort = 8775;
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

  valkey = mkContainerBackend "valkey" {
    image = valkeyImage;
    extraOptions = [ "--memory=128m" ];
  };

  searxng = mkContainerBackend "searxng" {
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
  my.images = {
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

  virtualisation.oci-containers.containers = valkey.containers // searxng.containers;
  systemd.services = valkey.systemdServices // searxng.systemdServices;

  # listen 先を環境変数でしか受けないので、env 経由でも ExecStart に現れる形で渡す
  my.mcp.targets.searxng = {
    port = frontPort;
    # web_url_read は SEARXNG_URL を経由せず引数の URL へ直接出る
    needsNetwork = true;
    serve =
      listenPort:
      "${pkgs.coreutils}/bin/env MCP_HTTP_HOST=127.0.0.1 MCP_HTTP_PORT=${toString listenPort} ${lib.getExe front}";
    waitUnits = [ "docker-searxng.service" ];
  };
  my.doctor.units = valkey.doctorUnits // searxng.doctorUnits;
}
