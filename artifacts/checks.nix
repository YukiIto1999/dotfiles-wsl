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
  artifactObservations = selectArtifactObservations hostConfig.dotfiles.observations;
  expectedArtifactObservations = artifactObservationsFor artifacts;
  artifactObservationKeys = builtins.attrNames expectedArtifactObservations;
  artifactObservationDefinitions = builtins.filter (
    definition: lib.hasSuffix "/artifacts/module.nix" (toString definition.file)
  ) hostOptions.dotfiles.observations.definitionsWithLocations;
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
        ../observations/module.nix
        ./module.nix
        { dotfiles.artifacts = candidateArtifacts; }
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
  requiredFormats = [
    "json"
    "toml"
    "yaml"
    "markdown"
  ];
  coversRequiredFormats =
    candidateArtifacts:
    lib.all (
      format: lib.any (artifact: artifact.format == format) (builtins.attrValues candidateArtifacts)
    ) requiredFormats;
  removeFormat = format: lib.filterAttrs (_: artifact: artifact.format != format);
  normalFormatEvaluation = builtins.tryEval (
    assert coversRequiredFormats artifacts;
    true
  );
  missingFormatEvaluations = map (
    format:
    builtins.tryEval (
      assert coversRequiredFormats (removeFormat format artifacts);
      true
    )
  ) requiredFormats;

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
    assert lib.assertMsg (coversRequiredFormats artifacts)
      "artifact registry must cover JSON, TOML, YAML, and Markdown";
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
    assert artifactContractMatches fixtureConfig.dotfiles.artifacts fixtureConfig.dotfiles.observations;
    assert
      builtins.attrNames (selectArtifactObservations fixtureConfig.dotfiles.observations) == [
        "artifacts/fixture/deployed"
      ];
    assert artifactContractMatches emptyFixtureConfig.dotfiles.artifacts
      emptyFixtureConfig.dotfiles.observations;
    pkgs.runCommandLocal "check-artifact-runtime-observation-contract" { } "touch $out";

  config-syntax =
    assert normalFormatEvaluation.success;
    assert lib.all (result: !result.success) missingFormatEvaluations;
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
