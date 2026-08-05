{
  pkgs,
  lib,
  self,
  hostConfig,
  hostOptions,
  variantConfig,
  ...
}:

let
  artifacts = hostConfig.dotfiles.artifacts;
  deployedArtifacts = lib.filterAttrs (_: artifact: artifact.deployedAt != null) artifacts;
  expectedDoctorArtifactTable = lib.mapAttrsToList (id: artifact: {
    inherit id;
    source = toString artifact.source;
    destination = artifact.deployedAt;
  }) deployedArtifacts;
  doctorArtifactTable = hostConfig.dotfiles.commands.doctor.tables.artifactTable;

  artifactSourcesFor =
    format:
    map (artifact: artifact.source) (
      builtins.attrValues (lib.filterAttrs (_: artifact: artifact.format == format) artifacts)
    );
  requiredFormats = [
    "json"
    "toml"
    "yaml"
    "markdown"
  ];

  ownerOf =
    declaration:
    let
      relative = lib.removePrefix "${self}/" (toString declaration);
    in
    builtins.head (lib.splitString "/" relative);

  misowned = lib.concatMap (
    definition:
    let
      owner = ownerOf definition.file;
    in
    builtins.filter (id: builtins.head (lib.splitString "/" id) != owner) (
      builtins.attrNames definition.value
    )
  ) hostOptions.dotfiles.artifacts.definitionsWithLocations;
in
{
  artifact-registry =
    assert lib.assertMsg (misowned == [ ]) (
      "artifact id first segment does not match its owner root: " + lib.concatStringsSep " " misowned
    );
    assert lib.assertMsg (
      doctorArtifactTable == expectedDoctorArtifactTable
    ) "doctor artifact table does not exactly match deployed artifacts";
    assert lib.assertMsg (lib.all (
      format: artifactSourcesFor format != [ ]
    ) requiredFormats) "artifact registry must cover JSON, TOML, YAML, and Markdown";
    assert builtins.attrNames variantConfig.dotfiles.artifacts == builtins.attrNames artifacts;
    assert variantConfig.dotfiles.accounts == hostConfig.dotfiles.accounts;
    assert
      variantConfig.sops.templates."gh-hosts.yml".content
      == hostConfig.sops.templates."gh-hosts.yml".content;
    assert
      hostConfig.dotfiles.accounts == [ ]
      ||
        hostConfig.sops.templates."gh-hosts.yml".content
        == builtins.readFile artifacts."accounts/gh-hosts".source;
    pkgs.runCommandLocal "check-artifact-registry" { } "touch $out";

  config-syntax =
    assert lib.all (format: artifactSourcesFor format != [ ]) requiredFormats;
    pkgs.runCommandLocal "check-config-syntax"
      {
        jsonSources = artifactSourcesFor "json";
        tomlSources = artifactSourcesFor "toml";
        yamlSources = artifactSourcesFor "yaml";
        markdownSources = artifactSourcesFor "markdown";
        nativeBuildInputs = [
          pkgs.jq
          pkgs.taplo
          pkgs.yq
        ];
      }
      ''
        set -euo pipefail

        for source in $jsonSources; do
          jq empty "$source"
        done
        for source in $tomlSources; do
          taplo lint "$source"
        done
        for source in $yamlSources; do
          yq . "$source" >/dev/null
        done
        for source in $markdownSources; do
          test -s "$source"
        done
        touch "$out"
      '';
}
