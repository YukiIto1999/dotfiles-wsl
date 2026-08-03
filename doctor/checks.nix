{
  pkgs,
  lib,
  self,
  hostConfig,
  ...
}:

let
  homeConfig = hostConfig.home-manager.users.${hostConfig.my.username};
  doctorManifest = hostConfig.environment.etc."dotfiles/doctor.json".source;
  codexProjectHomePath = "${lib.removePrefix "${hostConfig.my.homeDir}/" hostConfig.my.dotfilesDir}/.codex/config.toml";
  codexProjectConfig = homeConfig.home.file.${codexProjectHomePath}.source;
  gatewayFileLimit =
    lib.splitString ":"
      hostConfig.systemd.services."${hostConfig.my.contract.gateway.endpoints.default.service
      }".serviceConfig.LimitNOFILE;
  nixImageIdentityFiles = hostConfig.my.contract.images.identityFiles;
  fixtureNixImageFile = pkgs.writeText "fixture-agentmemory.tar.gz" "fixture";
  fixtureNixImageIdentityData = {
    schemaVersion = 1;
    imageReference = "agentmemory:fixture";
    imageFile = fixtureNixImageFile;
    imageId = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  };
  fixtureNixImageIdentity = pkgs.writeText "fixture-nix-image-identity-v1.json" (
    builtins.toJSON fixtureNixImageIdentityData
  );
  fixtureNixImageIdentityMalformed = pkgs.writeText "fixture-nix-image-identity-malformed.json" "{";
  fixtureNixImageIdentitySchema = pkgs.writeText "fixture-nix-image-identity-schema.json" (
    builtins.toJSON (fixtureNixImageIdentityData // { schemaVersion = 2; })
  );
  fixtureNixImageIdentityReference = pkgs.writeText "fixture-nix-image-identity-reference.json" (
    builtins.toJSON (fixtureNixImageIdentityData // { imageReference = "other:fixture"; })
  );
  fixtureNixImageIdentityFile = pkgs.writeText "fixture-nix-image-identity-file.json" (
    builtins.toJSON (fixtureNixImageIdentityData // { imageFile = "/nix/store/other.tar.gz"; })
  );
  fixtureNixImageIdentityId = pkgs.writeText "fixture-nix-image-identity-id.json" (
    builtins.toJSON (fixtureNixImageIdentityData // { imageId = "not-an-image-id"; })
  );
  fixtureNixImageIdentityCases = pkgs.writeText "fixture-nix-image-identity-cases.json" (
    builtins.toJSON {
      valid = fixtureNixImageIdentity;
      malformed = fixtureNixImageIdentityMalformed;
      schema = fixtureNixImageIdentitySchema;
      reference = fixtureNixImageIdentityReference;
      imageFile = fixtureNixImageIdentityFile;
      imageId = fixtureNixImageIdentityId;
    }
  );
  homeFiles = homeConfig.home.file;
  directHomeFilesIn =
    directory:
    lib.sort builtins.lessThan (
      map (lib.removePrefix "${directory}/") (
        builtins.filter (
          path:
          let
            relative = lib.removePrefix "${directory}/" path;
          in
          lib.hasPrefix "${directory}/" path && !lib.hasInfix "/" relative
        ) (builtins.attrNames homeFiles)
      )
    );
  expectedAgents = lib.mapAttrs (
    _: cli:
    if cli.agentsDir == null then
      null
    else
      {
        directory = "${hostConfig.my.homeDir}/${cli.agentsDir}";
        files = directHomeFilesIn cli.agentsDir;
      }
  ) hostConfig.my.clis;
  expectedAgentsJson = (pkgs.formats.json { }).generate "doctor-agents.json" expectedAgents;
  expectedWslInteropJson =
    (pkgs.formats.json { }).generate "doctor-wsl-interop.json"
      hostConfig.my.doctor.wslInterop;
  expectedDoctorUnits = lib.mapAttrsToList (id: unit: {
    inherit id;
    expected = lib.filterAttrs (_: value: value != null) unit.expected;
  }) hostConfig.my.doctor.units;
  expectedDoctorUnitsJson = (pkgs.formats.json { }).generate "doctor-units.json" expectedDoctorUnits;
  expectedManagedFiles = lib.mapAttrsToList (id: a: {
    inherit id;
    path = a.deployedAt;
    inherit (a) source;
  }) (lib.filterAttrs (_: a: a.deployedAt != null) hostConfig.my.artifacts);
  expectedManagedFilesJson =
    (pkgs.formats.json { }).generate "doctor-managed-files.json"
      expectedManagedFiles;
  expectedCliContracts = map (
    name:
    let
      cli = hostConfig.my.clis.${name};
    in
    {
      inherit name;
      binaryName = cli.binary;
      binaryPath = "${hostConfig.my.homeDir}/.local/bin/${cli.binary}";
      rules = {
        path = "${hostConfig.my.homeDir}/${cli.rulesFile}";
        source = homeFiles.${cli.rulesFile}.source;
      };
      skills = {
        directory = "${hostConfig.my.homeDir}/${cli.skillsDir}";
        names = directHomeFilesIn cli.skillsDir;
      };
      agents = expectedAgents.${name};
      gatewayFile =
        if cli.gatewayFile == null then
          null
        else
          {
            path = "${hostConfig.my.homeDir}/${cli.gatewayFile}";
            source = homeFiles.${cli.gatewayFile}.source;
          };
    }
  ) (builtins.attrNames hostConfig.my.clis);
  expectedCliContractsJson = (pkgs.formats.json { }).generate "doctor-clis.json" expectedCliContracts;
  # endpoint ごとの id と URL と health unit と target を、gateway の契約からそのまま期待値にする
  expectedMcpEndpointsJson = (pkgs.formats.json { }).generate "doctor-mcp-endpoints.json" (
    lib.mapAttrsToList (_: endpoint: {
      inherit (endpoint) id url targets;
      healthUnit = "${endpoint.service}.service";
    }) hostConfig.my.contract.gateway.endpoints
  );
  expectedProbePolicyJson =
    (pkgs.formats.json { }).generate "doctor-probe-policy.json"
      hostConfig.my.doctor.probePolicy;
  expectedDoctorOciImagesJson = (pkgs.formats.json { }).generate "doctor-oci-images.json" (
    lib.mapAttrsToList (id: image: {
      inherit id;
      inherit (image)
        kind
        container
        image
        repository
        digest
        ;
      unit = "docker-${image.container}.service";
      imageFile = if image.imageFile == null then null else toString image.imageFile;
      expectedImageIdFile = if image.kind == "nix" then toString nixImageIdentityFiles.${id} else null;
    }) hostConfig.my.images
  );
  codexProjectRuntimePath = "${hostConfig.my.dotfilesDir}/.codex/config.toml";
in
{
  doctor-manifest-contract =
    assert lib.all (id: builtins.hasAttr id hostConfig.systemd.units) (
      builtins.attrNames hostConfig.my.doctor.units
    );
    assert lib.all (
      endpoint: builtins.hasAttr "${endpoint.service}.service" hostConfig.my.doctor.units
    ) (builtins.attrValues hostConfig.my.contract.gateway.endpoints);
    pkgs.runCommandLocal "check-doctor-manifest-contract"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        set -euo pipefail

        jq --exit-status \
          --arg expectedPolicy ${
            lib.escapeShellArg (if hostConfig.my.sops.enrollmentState == "enrolled" then "reject" else "warn")
          } \
          --argjson expectedSchemaVersion ${toString hostConfig.my.doctor.schemaVersion} \
          '.schemaVersion == $expectedSchemaVersion and .sops.homeKey.policy == $expectedPolicy' \
          ${doctorManifest} > /dev/null

        jq --sort-keys 'sort_by(.id)' ${expectedDoctorUnitsJson} > expected-units.json
        jq --sort-keys '.units | sort_by(.id)' ${doctorManifest} > actual-units.json
        diff --unified expected-units.json actual-units.json

        jq --sort-keys 'sort_by(.id)' ${expectedManagedFilesJson} > expected-managed-files.json
        jq --sort-keys '.managedFiles | sort_by(.id)' ${doctorManifest} > actual-managed-files.json
        diff --unified expected-managed-files.json actual-managed-files.json

        jq --sort-keys 'sort_by(.name)' ${expectedCliContractsJson} > expected-clis.json
        jq --sort-keys '.clis | sort_by(.name)' ${doctorManifest} > actual-clis.json
        diff --unified expected-clis.json actual-clis.json

        jq --sort-keys 'sort_by(.id)' ${expectedMcpEndpointsJson} > expected-mcp-endpoints.json
        jq --sort-keys '[.mcp.endpoints[] | {id, url, targets, healthUnit}] | sort_by(.id)' ${doctorManifest} > actual-mcp-endpoints.json
        diff --unified expected-mcp-endpoints.json actual-mcp-endpoints.json

        jq --exit-status \
          --arg expectedHardLimit ${lib.escapeShellArg (builtins.elemAt gatewayFileLimit 1)} \
          --arg expectedSoftLimit ${lib.escapeShellArg (builtins.elemAt gatewayFileLimit 0)} '
          all(.mcp.endpoints[];
            .resources.properties == [
              "MainPID",
              "TasksCurrent",
              "MemoryCurrent",
              "MemorySwapCurrent",
              "LimitNOFILE",
              "LimitNOFILESoft"
            ] and
            .resources.expected.LimitNOFILE == $expectedHardLimit and
            .resources.expected.LimitNOFILESoft == $expectedSoftLimit
          )
        ' ${doctorManifest} > /dev/null

        jq --exit-status '
          .mcp.requestedProtocolVersion == "2025-11-25" and
          .mcp.supportedProtocolVersions == [
            "2024-11-05",
            "2025-03-26",
            "2025-06-18",
            "2025-11-25"
          ]
        ' ${doctorManifest} > /dev/null

        jq --sort-keys '.' ${expectedProbePolicyJson} > expected-probe-policy.json
        jq --sort-keys '.probePolicy' ${doctorManifest} > actual-probe-policy.json
        diff --unified expected-probe-policy.json actual-probe-policy.json

        jq --sort-keys 'sort_by(.id)' ${expectedDoctorOciImagesJson} > expected-oci-images.json
        jq --sort-keys '.oci.images | sort_by(.id)' ${doctorManifest} > actual-oci-images.json
        diff --unified expected-oci-images.json actual-oci-images.json

        jq --exit-status \
          --arg stateRoot ${lib.escapeShellArg "${hostConfig.my.homeDir}/.local/state/dotfiles-wsl/image-sync"} \
          --arg dockerCommand ${lib.escapeShellArg (lib.getExe pkgs.docker)} \
          --arg syncStatusCommand ${lib.escapeShellArg hostConfig.my.contract.images.syncStatusCommand} '
            .oci.healthUnit == "docker.service" and
            .oci.stateRoot == $stateRoot and
            .oci.dockerCommand == $dockerCommand and
            .oci.syncStatusCommand == $syncStatusCommand
          ' ${doctorManifest} > /dev/null

        jq --sort-keys '
          [.clis[] | {
            key: .name,
            value: (if .agents == null then null else {
              directory: .agents.directory,
              files: (.agents.files | sort)
            } end)
          }] | from_entries
        ' ${doctorManifest} > actual-agents.json
        jq --sort-keys \
          'with_entries(.value |= if . == null then null else (.files |= sort) end)' \
          ${expectedAgentsJson} > expected-agents.json
        diff --unified expected-agents.json actual-agents.json

        jq --exit-status \
          --slurpfile expected ${expectedWslInteropJson} \
          '.wslInterop == $expected[0]' \
          ${doctorManifest} > /dev/null

        jq --exit-status \
          --arg path ${lib.escapeShellArg codexProjectRuntimePath} \
          --arg source ${lib.escapeShellArg (toString codexProjectConfig)} \
          'any(.managedFiles[]; .id == "clis/codex/project" and .path == $path and .source == $source)' \
          ${doctorManifest} > /dev/null

        jq --exit-status \
          --arg path ${lib.escapeShellArg "${hostConfig.my.homeDir}/.config/opencode/plugins/agentmemory-capture.ts"} \
          --arg source ${
            lib.escapeShellArg (toString hostConfig.my.artifacts."mcp/memory/opencode-capture".source)
          } \
          'any(.managedFiles[];
            .id == "mcp/memory/opencode-capture" and
            .path == $path and
            .source == $source
          )' \
          ${doctorManifest} > /dev/null

        touch $out
      '';

  doctor-runtime =
    pkgs.runCommandLocal "check-doctor-runtime"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
          pkgs.util-linux
        ];
      }
      ''
        bash ${self}/doctor/tests/doctor-runtime.sh \
          ${self}/doctor/impl/doctor.sh \
          ${hostConfig.my.contract.primitives.libraries.atomicFile} \
          ${hostConfig.my.contract.images.libraries.imageState} \
          ${pkgs.bash}/bin/bash \
          ${fixtureNixImageIdentityCases} \
          ${toString hostConfig.my.doctor.schemaVersion}
        touch $out
      '';
}
