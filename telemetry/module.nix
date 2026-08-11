{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  collector = pkgs.opentelemetry-collector-contrib;

  # container を持たない。nixpkgs に binary があるので image 同期も docker 依存も要らない
  grpcPort = 4317;
  httpPort = 4318;
  stateDir = "dotfiles-telemetry";
  archive = "/var/lib/${stateDir}/otel.jsonl";
  serviceName = "otel-collector";
  serviceUnit = "${serviceName}.service";
  observationTimeoutSeconds = 10;
  restartWarningCount = 5;
  restartFailureCount = 20;

  telemetryObservations = {
    "telemetry/service/${serviceName}" = {
      kind = "systemd-service";
      checkId = "service/${serviceName}";
      resourceKey = null;
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "${serviceName} is not operational";
      unit = serviceUnit;
      loadStates = [ "loaded" ];
      activeStates = [ "active" ];
      results = [ "success" ];
    };
    "telemetry/service-restart/${serviceName}" = {
      kind = "restart-counter";
      checkId = "restart/service/${serviceName}";
      resourceKey = null;
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "could not observe restart count for ${serviceName}";
      sourceKind = "systemd-service";
      target = serviceName;
      warningAt = restartWarningCount;
      failureAt = restartFailureCount;
    };
  };

  collectorConfig = (pkgs.formats.yaml { }).generate "otelcol-config.yaml" {
    receivers.otlp.protocols = {
      grpc.endpoint = "127.0.0.1:${toString grpcPort}";
      http.endpoint = "127.0.0.1:${toString httpPort}";
    };

    processors.batch = { };

    # 集計せず生の record を残す。どの操作で token を使ったかは後から jq で追う
    exporters.file = {
      path = archive;
      rotation = {
        max_megabytes = 64;
        max_days = 30;
        max_backups = 8;
      };
    };

    service = {
      pipelines = lib.genAttrs [ "metrics" "logs" ] (_: {
        receivers = [ "otlp" ];
        processors = [ "batch" ];
        exporters = [ "file" ];
      });
      # collector 自身の metrics は観測対象ではない
      telemetry.metrics.level = "none";
    };
  };
in
{
  options.dotfiles.telemetry = {
    endpoint = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
    };
    protocol = lib.mkOption {
      type = lib.types.enum [ "grpc" ];
      readOnly = true;
      internal = true;
    };
    service = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
    };
    archive = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
    };
    ports = lib.mkOption {
      type = lib.types.attrsOf lib.types.port;
      readOnly = true;
      internal = true;
    };
  };

  config.dotfiles.artifacts."telemetry/collector" = {
    format = "yaml";
    deployedAt = "/etc/${stateDir}/collector.yaml";
    source = collectorConfig;
  };

  # CLI が読む契約。endpoint の決め方をここだけが持つ
  config.dotfiles.telemetry = {
    endpoint = "http://127.0.0.1:${toString grpcPort}";
    protocol = "grpc";
    service = serviceName;
    inherit archive;
    ports = {
      grpc = grpcPort;
      http = httpPort;
    };
  };

  config.dotfiles.observations = telemetryObservations;

  config.systemd.services.${serviceName} = {
    description = "OpenTelemetry collector for AI CLI usage";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = cfg.host.username;
      StateDirectory = stateDir;
      StateDirectoryMode = "0700";
      ExecStart = "${collector}/bin/otelcol-contrib --config ${collectorConfig}";
      MemoryMax = "512M";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  config.environment.etc."${stateDir}/collector.yaml".source = collectorConfig;

}
