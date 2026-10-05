{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  expectedSettingsPath = "/etc/searxng/settings.yml";
  expectedUnit = "docker-searxng.service";

  container = hostConfig.virtualisation.oci-containers.containers.searxng;
  secret = hostConfig.sops.secrets."searxng/secret_key";
  settingsTemplate = hostConfig.sops.templates."searxng-settings.yml";
  settingsArtifact = hostConfig.dotfiles.managedArtifacts."containers/searxng/settings-template";
  renderedSettings = pkgs.writeText "searxng-settings.yml" settingsTemplate.content;
in
{
  searxng-container =
    assert container.pull == "never";
    assert container.volumes == [ "${expectedSettingsPath}:${expectedSettingsPath}:ro" ];
    assert
      container.extraOptions == [
        "--init"
        "--network=dotfiles-backends"
        "--cgroup-parent=system.slice"
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
