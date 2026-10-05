{
  pkgs,
  hostConfig,
  hostOptions,
  ...
}:

let
  expectedEnvironmentFile = "/run/secrets/rendered/crawl4ai.env";
  expectedTokenFile = "/run/secrets/crawl4ai/api_token";
  expectedUnit = "docker-crawl4ai.service";

  container = hostConfig.virtualisation.oci-containers.containers.crawl4ai;
  token = hostConfig.sops.secrets."crawl4ai/api_token";
  environmentTemplate = hostConfig.sops.templates."crawl4ai.env";
  credentialOption = hostOptions.dotfiles.capabilities.web-content.crawl4ai.credentials.apiTokenFile;
in
{
  crawl4ai-container =
    assert container.pull == "never";
    assert container.environmentFiles == [ expectedEnvironmentFile ];
    assert
      container.extraOptions == [
        "--init"
        "--network=dotfiles-backends"
        "--cgroup-parent=system.slice"
        "--memory=4g"
        "--shm-size=1g"
        "-p"
        "127.0.0.1:11235:11235"
      ];
    assert token.path == expectedTokenFile;
    assert token.mode == "0400";
    assert token.owner == "nixos";
    assert token.group == "users";
    assert credentialOption.type.name == "str";
    assert credentialOption.readOnly or false;
    assert
      hostConfig.dotfiles.capabilities.web-content.crawl4ai.credentials.apiTokenFile == expectedTokenFile;
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
