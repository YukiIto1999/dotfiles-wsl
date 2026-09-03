{
  pkgs,
  lib,
  self,
  hostConfig,
  hostOptions,
  variantConfig,
  helpers,
  ...
}:

let
  artifacts = hostConfig.dotfiles.managedArtifacts;
  deployedArtifacts = lib.filterAttrs (_: artifact: artifact.deployedAt != null) artifacts;

  artifactObservationsFor =
    candidateArtifacts:
    lib.mapAttrs' (
      id: artifact:
      lib.nameValuePair "artifacts/${id}" {
        kind = "deployed-path";
        checkId = "artifact/${id}";
        resourceKey = null;
        timeoutSeconds = 10;
        failureMessage = "${artifact.deployedAt} does not match ${toString artifact.source}";
        source = toString artifact.source;
        destination = artifact.deployedAt;
        acceptedDestinationKinds = [
          "regular-file"
          "symlink"
        ];
      }
    ) (lib.filterAttrs (_: artifact: artifact.deployedAt != null) candidateArtifacts);
  selectArtifactObservations = lib.filterAttrs (name: _: lib.hasPrefix "artifacts/" name);
  artifactObservations = selectArtifactObservations hostConfig.dotfiles.health.observations;
  expectedArtifactObservations = artifactObservationsFor artifacts;
  artifactObservationKeys = builtins.attrNames expectedArtifactObservations;
  artifactObservationDefinitions = builtins.filter (
    definition: lib.hasSuffix "/managed-artifacts/module.nix" (toString definition.file)
  ) hostOptions.dotfiles.health.observations.definitionsWithLocations;
  artifactDefinitionKeys = lib.unique (
    lib.concatMap (definition: builtins.attrNames definition.value) artifactObservationDefinitions
  );
  uniqueNonNull =
    field: observations:
    let
      values = builtins.filter (value: value != null) (
        map (observation: observation.${field}) (builtins.attrValues observations)
      );
    in
    builtins.length values == builtins.length (lib.unique values);
  artifactContractMatches =
    candidateArtifacts: candidateObservations:
    selectArtifactObservations candidateObservations == artifactObservationsFor candidateArtifacts;

  deployedArtifactIds = builtins.attrNames deployedArtifacts;
  sampleArtifactId = builtins.head deployedArtifactIds;
  sampleObservationKey = "artifacts/${sampleArtifactId}";
  missingObservationMutation = builtins.removeAttrs artifactObservations [ sampleObservationKey ];
  changedObservationMutation = artifactObservations // {
    ${sampleObservationKey} = artifactObservations.${sampleObservationKey} // {
      destination = "/tmp/changed-artifact-destination";
    };
  };
  staleObservationMutation = artifactObservations // {
    "artifacts/stale" = artifactObservations.${sampleObservationKey};
  };
  foreignObservationMutation = artifactObservations // {
    "host/independent-artifact-fixture" = artifactObservations.${sampleObservationKey};
  };

  evalArtifactConfig =
    candidateArtifacts:
    (lib.evalModules {
      modules = [
        helpers.observationRegistryModule
        ./module.nix
        { dotfiles.managedArtifacts = candidateArtifacts; }
      ];
    }).config;
  fixtureSource = pkgs.writeText "artifact-observation-fixture" "fixture";
  fixtureArtifacts = {
    "fixture/deployed" = {
      format = "text";
      deployedAt = "/etc/dotfiles-fixture";
      source = fixtureSource;
    };
    "fixture/source-only" = {
      format = "text";
      source = fixtureSource;
    };
  };
  fixtureConfig = evalArtifactConfig fixtureArtifacts;
  emptyFixtureConfig = evalArtifactConfig { };

  artifactSourcesFor =
    format:
    map (artifact: artifact.source) (
      builtins.attrValues (lib.filterAttrs (_: artifact: artifact.format == format) artifacts)
    );
  supportedFormats = [
    "json"
    "toml"
    "yaml"
    "markdown"
  ];
  formatFixtures = {
    json = pkgs.writeText "artifact-format-fixture.json" "{}";
    markdown = pkgs.writeText "artifact-format-fixture.md" "# fixture";
    toml = pkgs.writeText "artifact-format-fixture.toml" "fixture = true";
    yaml = pkgs.writeText "artifact-format-fixture.yaml" "fixture: true";
  };
  syntaxSourcesFor = format: [ formatFixtures.${format} ] ++ artifactSourcesFor format;

  ownerOf =
    declaration:
    let
      relative = lib.removePrefix "${self}/" (toString declaration);
    in
    builtins.head (lib.splitString "/" relative);
  ownerRootForIdSegment =
    segment:
    {
      accounts = "identity";
      containers = "capabilities";
      mcp = "platform";
    }
    .${segment} or segment;

  misowned = lib.concatMap (
    definition:
    let
      owner = ownerOf definition.file;
    in
    builtins.filter (
      id:
      let
        segment = builtins.head (lib.splitString "/" id);
      in
      ownerRootForIdSegment segment != owner
    ) (builtins.attrNames definition.value)
  ) hostOptions.dotfiles.managedArtifacts.definitionsWithLocations;
in
{
  artifact-registry =
    assert lib.assertMsg (misowned == [ ]) (
      "artifact id owner segment does not match its physical owner root: "
      + lib.concatStringsSep " " misowned
    );
    assert builtins.attrNames variantConfig.dotfiles.managedArtifacts == builtins.attrNames artifacts;
    pkgs.runCommandLocal "check-artifact-registry" { } "touch $out";

  artifact-runtime-observation-contract =
    assert deployedArtifactIds != [ ];
    assert lib.assertMsg (
      artifactObservations == expectedArtifactObservations
    ) "artifact runtime observation registry is incomplete";
    assert lib.assertMsg (
      artifactDefinitionKeys == artifactObservationKeys
    ) "artifact observations must be defined by the artifacts owner";
    assert lib.assertMsg (uniqueNonNull "checkId" artifactObservations)
      "artifact runtime observation check IDs must be unique";
    assert lib.assertMsg (uniqueNonNull "resourceKey" artifactObservations)
      "artifact runtime observation resource keys must be unique";
    assert lib.all (observation: observation.resourceKey == null) (
      builtins.attrValues artifactObservations
    );
    assert !(artifactContractMatches artifacts missingObservationMutation);
    assert !(artifactContractMatches artifacts changedObservationMutation);
    assert !(artifactContractMatches artifacts staleObservationMutation);
    assert artifactContractMatches artifacts foreignObservationMutation;
    assert artifactContractMatches fixtureConfig.dotfiles.managedArtifacts
      fixtureConfig.dotfiles.health.observations;
    assert
      builtins.attrNames (selectArtifactObservations fixtureConfig.dotfiles.health.observations) == [
        "artifacts/fixture/deployed"
      ];
    assert artifactContractMatches emptyFixtureConfig.dotfiles.managedArtifacts
      emptyFixtureConfig.dotfiles.health.observations;
    pkgs.runCommandLocal "check-artifact-runtime-observation-contract" { } "touch $out";

  config-syntax =
    assert builtins.attrNames formatFixtures == lib.sort builtins.lessThan supportedFormats;
    pkgs.runCommandLocal "check-config-syntax"
      {
        jsonSources = syntaxSourcesFor "json";
        tomlSources = syntaxSourcesFor "toml";
        yamlSources = syntaxSourcesFor "yaml";
        markdownSources = syntaxSourcesFor "markdown";
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
