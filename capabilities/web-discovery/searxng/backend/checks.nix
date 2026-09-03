{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  expectedRepository = "searxng/searxng";
  expectedDigest = "sha256:ec536bcd1e83577aad4cc07f7ecb9a30858a9a905d2d57c8796abc83f872a036";
  expectedImage = "${expectedRepository}:2026.8.1-8892414dc@${expectedDigest}";
  expectedSettingsPath = "/etc/searxng/settings.yml";
  expectedUnit = "docker-searxng.service";
  expectedService = {
    endpoints.http = {
      protocol = "http";
      address = "127.0.0.1";
      port = 8080;
      url = "http://127.0.0.1:8080";
    };
    units = [ expectedUnit ];
    containerPolicy.secretReaders."searxng-settings.yml" = [ "searxng" ];
    containerPolicy.volumeOwners = { };
    images.searxng = {
      kind = "upstream";
      container = "searxng";
      image = expectedImage;
      repository = expectedRepository;
      digest = expectedDigest;
      imageFile = null;
    };
    health = {
      endpoint = "http";
      method = "GET";
      path = "/healthz";
      timeout = 5;
    };
  };

  service = hostConfig.dotfiles.platform.containers.services.searxng;
  container = hostConfig.virtualisation.oci-containers.containers.searxng;
  secret = hostConfig.sops.secrets."searxng/secret_key";
  settingsTemplate = hostConfig.sops.templates."searxng-settings.yml";
  settingsArtifact = hostConfig.dotfiles.managedArtifacts."containers/searxng/settings-template";
  renderedSettings = pkgs.writeText "searxng-settings.yml" settingsTemplate.content;
in
{
  searxng-container =
    assert service == expectedService;
    assert container.image == expectedImage;
    assert container.pull == "never";
    assert container.volumes == [ "${expectedSettingsPath}:${expectedSettingsPath}:ro" ];
    assert
      container.extraOptions == [
        "--network=dotfiles-backends"
        "--memory=512m"
        "-p"
        "127.0.0.1:8080:8080"
      ];
    assert secret.path == "/run/secrets/searxng/secret_key";
    assert secret.mode == "0400";
    assert secret.owner == "root";
    assert secret.group == "root";
    assert settingsTemplate.path == expectedSettingsPath;
    assert settingsTemplate.mode == "0400";
    assert settingsTemplate.owner == "root";
    assert settingsTemplate.group == "root";
    assert settingsTemplate.restartUnits == [ expectedUnit ];
    assert settingsArtifact.format == "yaml";
    assert !(builtins.hasAttr "mcp/searxng/settings-template" hostConfig.dotfiles.managedArtifacts);
    pkgs.runCommandLocal "check-searxng-container" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      set -euo pipefail

      diff -u ${settingsArtifact.source} ${renderedSettings}
      test "$(yq -r '.server.port' ${settingsArtifact.source})" = 8080
      test "$(yq -r '.server.bind_address' ${settingsArtifact.source})" = 0.0.0.0
      test "$(yq -r '.server.secret_key' ${settingsArtifact.source})" = ${
        lib.escapeShellArg hostConfig.sops.placeholder."searxng/secret_key"
      }
      touch $out
    '';
}
