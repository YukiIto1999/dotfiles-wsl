{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my;
  collector = pkgs.opentelemetry-collector-contrib;

  # container を持たない。nixpkgs に binary があるので image 同期も docker 依存も要らない
  grpcPort = 4317;
  httpPort = 4318;
  stateDir = "dotfiles-telemetry";
  archive = "/var/lib/${stateDir}/otel.jsonl";

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
  config.my.configArtifacts."telemetry/collector" = {
    format = "yaml";
    source = collectorConfig;
  };

  # CLI が読む契約。endpoint の決め方をここだけが持つ
  config.my.contract.telemetry = {
    endpoint = "http://127.0.0.1:${toString grpcPort}";
    protocol = "grpc";
    service = "otel-collector";
    inherit archive;
    ports = {
      grpc = grpcPort;
      http = httpPort;
    };
  };

  config.systemd.services.otel-collector = {
    description = "OpenTelemetry collector for AI CLI usage";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = cfg.username;
      StateDirectory = stateDir;
      StateDirectoryMode = "0700";
      ExecStart = "${collector}/bin/otelcol-contrib --config ${collectorConfig}";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  config.environment.etc."${stateDir}/collector.yaml".source = collectorConfig;

  config.my.doctor = {
    units."otel-collector.service".expected = {
      LoadState = "loaded";
      ActiveState = "active";
      SubState = "running";
      Result = "success";
    };
    managedFiles.telemetry = {
      path = "/etc/${stateDir}/collector.yaml";
      source = collectorConfig;
    };
  };
}
