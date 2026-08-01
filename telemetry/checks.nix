{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  contract = hostConfig.my.contract.telemetry;
  collectorConfig = hostConfig.my.configArtifacts."telemetry/collector".source;
  service = hostConfig.systemd.services.${contract.service}.serviceConfig;
in
{
  # config の妥当性は schema の読みではなく collector 自身に判定させる
  telemetry-collector-config =
    assert lib.hasSuffix "--config ${collectorConfig}" service.ExecStart;
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
        touch $out
      '';
}
