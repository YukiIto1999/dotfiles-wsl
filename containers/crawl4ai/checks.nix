{
  pkgs,
  hostConfig,
  hostOptions,
  ...
}:

let
  expectedRepository = "unclecode/crawl4ai";
  expectedDigest = "sha256:bd36741e7bdd35ddc1a05d9183e1d6d8cefb61dd640d944a25d026b76e917690";
  expectedImage = "${expectedRepository}:latest@${expectedDigest}";
  expectedEnvironmentFile = "/run/secrets/rendered/crawl4ai.env";
  expectedTokenFile = "/run/secrets/crawl4ai/api_token";
  expectedUnit = "docker-crawl4ai.service";
  expectedFrontUnit = "mcp-front-crawl4ai.service";
  expectedService = {
    endpoints.http = {
      protocol = "http";
      address = "127.0.0.1";
      port = 11235;
      url = "http://127.0.0.1:11235";
    };
    units = [ expectedUnit ];
    images.crawl4ai = {
      kind = "upstream";
      container = "crawl4ai";
      image = expectedImage;
      repository = expectedRepository;
      digest = expectedDigest;
      imageFile = null;
    };
    health = {
      endpoint = "http";
      method = "GET";
      path = "/health";
      timeout = 5;
    };
  };

  service = hostConfig.dotfiles.containers.services.crawl4ai;
  container = hostConfig.virtualisation.oci-containers.containers.crawl4ai;
  token = hostConfig.sops.secrets."crawl4ai/api_token";
  environmentTemplate = hostConfig.sops.templates."crawl4ai.env";
  credentialOption = hostOptions.dotfiles.containers.crawl4ai.credentials.apiTokenFile;
in
{
  crawl4ai-container =
    assert service == expectedService;
    assert container.image == expectedImage;
    assert container.pull == "never";
    assert container.environmentFiles == [ expectedEnvironmentFile ];
    assert
      container.extraOptions == [
        "--network=dotfiles-backends"
        "--memory=4g"
        "--shm-size=1g"
        "-p"
        "127.0.0.1:11235:11235"
      ];
    assert token.path == expectedTokenFile;
    assert token.mode == "0400";
    assert token.owner == "nixos";
    assert token.group == "users";
    assert token.restartUnits == [ expectedFrontUnit ];
    assert credentialOption.type.name == "str";
    assert credentialOption.readOnly or false;
    assert hostConfig.dotfiles.containers.crawl4ai.credentials.apiTokenFile == expectedTokenFile;
    assert environmentTemplate.path == expectedEnvironmentFile;
    assert environmentTemplate.mode == "0400";
    assert environmentTemplate.owner == "root";
    assert environmentTemplate.group == "root";
    assert environmentTemplate.restartUnits == [ expectedUnit ];
    assert
      environmentTemplate.content == ''
        CRAWL4AI_API_TOKEN=${hostConfig.sops.placeholder."crawl4ai/api_token"}
      '';
    pkgs.runCommandLocal "check-crawl4ai-container" { } "touch $out";
}
