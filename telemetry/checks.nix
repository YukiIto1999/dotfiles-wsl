{
  helpers,
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  mkNixosSystem,
  normalMachineModule,
  ...
}:

let
  inherit (helpers.execTokens) tokensOf onlyValue valuesOf;
  contract = hostConfig.dotfiles.telemetry;
  collectorConfig = hostConfig.dotfiles.artifacts."telemetry/collector".source;
  service = hostConfig.systemd.services.${contract.service}.serviceConfig;

  telemetryObservationsFor =
    telemetryContract:
    let
      serviceName = telemetryContract.service;
      serviceUnit = "${serviceName}.service";
      common = checkId: failureMessage: {
        inherit checkId failureMessage;
        resourceKey = null;
        timeoutSeconds = 10;
      };
    in
    {
      "telemetry/service/${serviceName}" =
        common "service/${serviceName}" "${serviceName} is not operational"
        // {
          kind = "systemd-service";
          unit = serviceUnit;
          loadStates = [ "loaded" ];
          activeStates = [ "active" ];
          results = [ "success" ];
        };
      "telemetry/service-restart/${serviceName}" =
        common "restart/service/${serviceName}" "could not observe restart count for ${serviceName}"
        // {
          kind = "restart-counter";
          sourceKind = "systemd-service";
          target = serviceName;
          warningAt = 5;
          failureAt = 20;
        };
    };
  selectTelemetryObservations = lib.filterAttrs (name: _: lib.hasPrefix "telemetry/" name);
  telemetryObservations = selectTelemetryObservations hostConfig.dotfiles.observations;
  expectedTelemetryObservations = telemetryObservationsFor contract;
  telemetryObservationKeys = builtins.attrNames expectedTelemetryObservations;
  telemetryObservationDefinitions = builtins.filter (
    definition: lib.hasSuffix "/telemetry/module.nix" (toString definition.file)
  ) hostOptions.dotfiles.observations.definitionsWithLocations;
  telemetryDefinitionKeys = lib.unique (
    lib.concatMap (definition: builtins.attrNames definition.value) telemetryObservationDefinitions
  );
  uniqueNonNull =
    field: observations:
    let
      values = builtins.filter (value: value != null) (
        map (observation: observation.${field}) (builtins.attrValues observations)
      );
    in
    builtins.length values == builtins.length (lib.unique values);
  telemetryContractMatches =
    telemetryContract: candidateObservations:
    selectTelemetryObservations candidateObservations == telemetryObservationsFor telemetryContract;

  serviceObservationKey = "telemetry/service/${contract.service}";
  restartObservationKey = "telemetry/service-restart/${contract.service}";
  missingServiceMutation = builtins.removeAttrs telemetryObservations [ serviceObservationKey ];
  missingRestartMutation = builtins.removeAttrs telemetryObservations [ restartObservationKey ];
  changedObservationMutation = telemetryObservations // {
    ${serviceObservationKey} = telemetryObservations.${serviceObservationKey} // {
      results = [ "exit-code" ];
    };
  };
  staleObservationMutation = telemetryObservations // {
    "telemetry/service/stale" = telemetryObservations.${serviceObservationKey};
  };
  foreignObservationMutation = telemetryObservations // {
    "host/independent-telemetry-fixture" = telemetryObservations.${serviceObservationKey};
  };

  descriptionVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      (
        { lib, ... }:
        {
          systemd.services.${contract.service}.description =
            lib.mkForce "Descriptions must not select telemetry observations";
          systemd.services.telemetry-unowned = {
            description = "An unrelated service must not join telemetry observations";
            serviceConfig.Type = "oneshot";
            script = "true";
          };
        }
      )
    ]).config;
  descriptionVariantObservations = selectTelemetryObservations (
    descriptionVariantConfig.dotfiles.observations
  );
in
{
  # config の妥当性は schema の読みではなく collector 自身に判定させる
  telemetry-collector-config =
    assert onlyValue (tokensOf service.ExecStart) "--config" (toString collectorConfig);
    # --set は config を後から上書きする
    assert valuesOf (tokensOf service.ExecStart) "--set" == [ ];
    assert contract.endpoint == "http://127.0.0.1:${toString contract.ports.grpc}";
    pkgs.runCommandLocal "check-telemetry-collector-config"
      {
        nativeBuildInputs = [
          pkgs.opentelemetry-collector-contrib
          pkgs.yq-go
        ];
      }
      ''
        set -euo pipefail

        otelcol-contrib validate --config ${collectorConfig}

        # loopback を外れると、到達できる process が観測記録を書き込める
        for protocol in grpc http; do
          endpoint=$(yq -r ".receivers.otlp.protocols.$protocol.endpoint" ${collectorConfig})
          case $endpoint in
            127.0.0.1:*) ;;
            *)
              echo "otlp $protocol receiver is not bound to loopback: $endpoint" >&2
              exit 1
              ;;
          esac
        done

        test "$(yq -r '.receivers.otlp.protocols.grpc.endpoint' ${collectorConfig})" \
          = "127.0.0.1:${toString contract.ports.grpc}"
        test "$(yq -r '.receivers.otlp.protocols.http.endpoint' ${collectorConfig})" \
          = "127.0.0.1:${toString contract.ports.http}"
        test "$(yq -r '.exporters.file.path' ${collectorConfig})" = ${lib.escapeShellArg contract.archive}
        # collector 自身の metrics を出すと、目録に無い listener が 8888 に増える
        test "$(yq -r '.service.telemetry.metrics.level' ${collectorConfig})" = none
        touch $out
      '';

  telemetry-runtime-observation-contract =
    assert builtins.hasAttr contract.service hostConfig.systemd.services;
    assert lib.assertMsg (
      telemetryObservations == expectedTelemetryObservations
    ) "telemetry runtime observation registry is incomplete";
    assert lib.assertMsg (
      telemetryDefinitionKeys == telemetryObservationKeys
    ) "telemetry observations must be defined by the telemetry owner";
    assert
      builtins.attrNames telemetryObservations == [
        restartObservationKey
        serviceObservationKey
      ];
    assert telemetryObservations.${serviceObservationKey}.unit == "${contract.service}.service";
    assert telemetryObservations.${serviceObservationKey}.checkId == "service/${contract.service}";
    assert telemetryObservations.${restartObservationKey}.target == contract.service;
    assert
      telemetryObservations.${restartObservationKey}.checkId == "restart/service/${contract.service}";
    assert lib.all (observation: observation.resourceKey == null) (
      builtins.attrValues telemetryObservations
    );
    assert lib.assertMsg (uniqueNonNull "checkId" telemetryObservations)
      "telemetry runtime observation check IDs must be unique";
    assert lib.assertMsg (uniqueNonNull "resourceKey" telemetryObservations)
      "telemetry runtime observation resource keys must be unique";
    assert !(telemetryContractMatches contract missingServiceMutation);
    assert !(telemetryContractMatches contract missingRestartMutation);
    assert !(telemetryContractMatches contract changedObservationMutation);
    assert !(telemetryContractMatches contract staleObservationMutation);
    assert telemetryContractMatches contract foreignObservationMutation;
    assert descriptionVariantObservations == telemetryObservations;
    assert builtins.hasAttr "telemetry-unowned" descriptionVariantConfig.systemd.services;
    pkgs.runCommandLocal "check-telemetry-runtime-observation-contract" { } "touch $out";
}
