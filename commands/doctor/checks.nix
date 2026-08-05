{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  mkDoctor = import ./package.nix;
  fixtureArtifactDestination = pkgs.writeText "dotfiles-doctor-deployed-rules.md" "fixture";
  fixtureArtifactSource = pkgs.writeText "dotfiles-doctor-source-rules.md" "fixture";
  fixtureGatewayDestination = pkgs.writeText "dotfiles-doctor-deployed-gateway.yaml" "config: fixture";
  fixtureGatewaySource = pkgs.writeText "dotfiles-doctor-source-gateway.yaml" "config: fixture";

  tables = {
    agentTable = [
      {
        id = "claude";
        binary = "claude";
        versionArgs = [ "--version" ];
      }
    ];
    artifactTable = [
      {
        id = "agents/claude/rules";
        source = toString fixtureArtifactSource;
        destination = toString fixtureArtifactDestination;
      }
      {
        id = "mcp/gateway/default/config";
        source = toString fixtureGatewaySource;
        destination = toString fixtureGatewayDestination;
      }
    ];
    secretTable = [
      {
        id = "fixture";
        path = "/run/secrets/fixture";
        owner = "root";
        group = "root";
        mode = "0400";
      }
    ];
    serviceTable = [
      {
        role = "home-manager";
        unit = "home-manager-alice.service";
      }
    ];
    containerTable = [
      {
        application = "sonarqube";
        container = "sonarqube";
        image = "sonarqube:fixture";
      }
    ];
    healthTable = [
      {
        application = "sonarqube";
        method = "GET";
        timeout = 10;
        url = "http://127.0.0.1:9000/api/system/status";
      }
    ];
    mcpTable = [
      {
        id = "sonarqube";
        probe = {
          tool = "system_status";
          args = { };
          timeout = 10;
        };
      }
    ];
    gatewayUrl = "http://127.0.0.1:8765/mcp";
  };

  fakeTools = pkgs.runCommandLocal "dotfiles-doctor-fixture-tools" { } ''
    mkdir -p "$out/bin" "$out/libexec"
    cp ${./fixtures/fake-tool.sh} "$out/libexec/fake-tool"
    patchShebangs "$out/libexec/fake-tool"
    for name in curl docker readlink stat systemctl cmp claude unknown-agent; do
      ln -s ../libexec/fake-tool "$out/bin/$name"
    done
  '';

  injectedTools = {
    curl = "${fakeTools}/bin/curl";
    docker = "${fakeTools}/bin/docker";
    jq = lib.getExe pkgs.jq;
    cmp = "${fakeTools}/bin/cmp";
    readlink = "${fakeTools}/bin/readlink";
    stat = "${fakeTools}/bin/stat";
    systemctl = "${fakeTools}/bin/systemctl";
  };

  fixtureDoctor = mkDoctor {
    inherit pkgs lib;
    tools = injectedTools;
    inherit tables;
  };

  emptyRosterDoctor = mkDoctor {
    inherit pkgs lib;
    tools = injectedTools;
    tables = tables // {
      mcpTable = [ ];
    };
  };

  baseFixture = pkgs.writeText "dotfiles-doctor-base-fixture.json" (
    builtins.toJSON {
      system = {
        current = "/nix/store/system";
        profile = "/nix/store/system";
      };
      systemd."home-manager-alice.service" = {
        LoadState = "loaded";
        ActiveState = "active";
        Result = "success";
      };
      binaries.claude = {
        stdout = "fixture 1.0";
        exit = 0;
      };
      artifacts = {
        "agents/claude/rules".equal = true;
        "mcp/gateway/default/config".equal = true;
      };
      secrets."/run/secrets/fixture".metadata = "root:root:400";
      docker = {
        images."sonarqube:fixture".imageId = "sha256:declared";
        containers.sonarqube.imageId = "sha256:declared";
      };
      health."http://127.0.0.1:9000/api/system/status" = {
        status = 200;
        body = ''{"status":"UP"}'';
      };
      mcp = {
        sessionId = "fixture-session";
        protocolVersion = "2025-06-18";
        responseContentType = "text/event-stream";
        sseEvents = [ ];
        tools = [ "sonarqube_system_status" ];
        calls.sonarqube.result.content = [ ];
        notificationStatus = 202;
        deleteStatus = 204;
      };
    }
  );

  fixtureTables = builtins.toJSON tables;

  productionTables = hostConfig.dotfiles.commands.doctor.tables;
  expectedServiceUnits = lib.unique (
    [
      "home-manager-${hostConfig.dotfiles.host.username}.service"
      hostConfig.dotfiles.telemetry.service
      hostConfig.dotfiles.mcp.gateway.service
    ]
    ++ lib.concatMap (service: service.units) (
      builtins.attrValues hostConfig.dotfiles.containers.services
    )
    ++ map (front: front.service) (builtins.attrValues hostConfig.dotfiles.mcp.fronts)
  );
in
{
  doctor-coverage =
    assert builtins.length tables.agentTable == 1;
    assert builtins.length tables.artifactTable == 2;
    assert builtins.length tables.secretTable == 1;
    assert builtins.length tables.serviceTable == 1;
    assert builtins.length tables.containerTable == 1;
    assert builtins.length tables.healthTable == 1;
    assert builtins.length tables.mcpTable == 1;
    assert tables.gatewayUrl != "";
    assert
      builtins.attrNames productionTables == [
        "agentTable"
        "artifactTable"
        "containerTable"
        "gatewayUrl"
        "healthTable"
        "mcpTable"
        "secretTable"
        "serviceTable"
      ];
    assert map (row: row.id) productionTables.agentTable == hostConfig.dotfiles.agents.enabled;
    assert lib.all (
      row: row.owner != null && row.group != null && row.mode != ""
    ) productionTables.secretTable;
    assert map (row: row.unit) productionTables.serviceTable == expectedServiceUnits;
    assert
      builtins.length (builtins.filter (row: row.role == "home-manager") productionTables.serviceTable)
      == 1;
    assert
      (builtins.head (builtins.filter (row: row.role == "home-manager") productionTables.serviceTable))
      .unit == "home-manager-${hostConfig.dotfiles.host.username}.service";
    assert
      map (row: row.application) productionTables.healthTable == hostConfig.dotfiles.containers.enabled;
    assert
      map (row: row.id) productionTables.mcpTable == builtins.attrNames hostConfig.dotfiles.mcp.targets;
    assert productionTables.gatewayUrl == hostConfig.dotfiles.mcp.gateway.url;
    pkgs.runCommandLocal "check-doctor-coverage" { } ''
      test -x ${lib.getExe hostConfig.dotfiles.commands.doctor}
      touch "$out"
    '';

  doctor-runtime =
    pkgs.runCommandLocal "check-doctor-runtime"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        set -euo pipefail

        export PATH=${fakeTools}/bin:$PATH
        export DOTFILES_DOCTOR_TABLES=${lib.escapeShellArg fixtureTables}

        merge_fixture() {
          local name=$1
          jq -s '.[0] * .[1]' ${baseFixture} ${./fixtures}/"$name.json" > "$TMPDIR/$name.json"
        }

        run_case() {
          local name=$1
          local expected_status=$2
          local expected_failures=$3
          local doctor=$4
          local output status

          merge_fixture "$name"
          set +e
          output=$(DOTFILES_DOCTOR_FIXTURE="$TMPDIR/$name.json" "$doctor" --json)
          status=$?
          set -e

          if [[ $status -ne $expected_status ]]; then
            printf '%s expected exit %s, got %s\n%s\n' "$name" "$expected_status" "$status" "$output" >&2
            return 1
          fi

          if ! jq -e . >/dev/null <<<"$output"; then
            printf '%s did not emit valid JSON\n%s\n' "$name" "$output" >&2
            return 1
          fi
          if ! jq -e --argjson expected "$expected_failures" \
            '(.failures | map(.id)) == $expected' >/dev/null <<<"$output"; then
            printf '%s did not report exact failures %s\n%s\n' "$name" "$expected_failures" "$output" >&2
            return 1
          fi
          if ! jq -e '
            ([.checks[] | select(.id == "home-manager")] | length) == 1
            and ([.checks[] | select(.id == "service/home-manager-alice.service")] | length) == 0
          ' >/dev/null <<<"$output"; then
            printf '%s did not probe the Home Manager inventory row exactly once\n%s\n' "$name" "$output" >&2
            return 1
          fi
        }

        test_failures=0
        run_case missing-session 1 '["mcp-session"]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case jsonrpc-error 1 '["mcp-target/sonarqube"]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case image-mismatch 1 '["container-image/sonarqube"]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case stale-artifact 1 '["artifact/agents/claude/rules"]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case stale-gateway 1 '["artifact/mcp/gateway/default/config"]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case direct-json 0 '[]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case multi-event-sse 0 '[]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case invalid-protocol 1 '["mcp-session"]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case tool-error 1 '["mcp-target/sonarqube"]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case delete-405 0 '[]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case healthy 0 '[]' ${lib.getExe fixtureDoctor} || test_failures=1
        run_case healthy 1 '["mcp-roster"]' ${lib.getExe emptyRosterDoctor} || test_failures=1

        if run_case extra-failure 1 '["mcp-target/sonarqube"]' ${lib.getExe fixtureDoctor} \
          >/dev/null 2>&1; then
          printf 'extra-failure accepted an incomplete expected failure ID array\n' >&2
          test_failures=1
        fi

        expect_contract_rejection() {
          local label=$1
          shift
          local status

          set +e
          "$@" >/dev/null 2>&1
          status=$?
          set -e
          if [[ $status -ne 64 ]]; then
            printf '%s expected fixture contract exit 64, got %s\n' "$label" "$status" >&2
            test_failures=1
          fi
        }

        merge_fixture healthy
        export DOTFILES_DOCTOR_FIXTURE="$TMPDIR/healthy.json"

        jq -cn \
          '{jsonrpc:"2.0",method:"notifications/initialized",params:{}}' \
          > "$TMPDIR/notification.json"
        jq -cn \
          '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"sonarqube_system_status",arguments:{unexpected:true}}}' \
          > "$TMPDIR/wrong-args.json"
        jq -cn \
          '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"sonarqube_system_status",arguments:{}}}' \
          > "$TMPDIR/call.json"
        jq -cn \
          '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"unknown_system_status",arguments:{}}}' \
          > "$TMPDIR/unknown-target.json"

        expect_contract_rejection version-args ${fakeTools}/bin/claude --help
        expect_contract_rejection unknown-agent ${fakeTools}/bin/unknown-agent --version
        expect_contract_rejection unknown-unit ${fakeTools}/bin/systemctl show unknown.service --property=LoadState --value
        expect_contract_rejection unknown-property ${fakeTools}/bin/systemctl show home-manager-alice.service --property=Unknown --value
        expect_contract_rejection wrong-session ${fakeTools}/bin/curl \
          --silent --show-error --fail-with-body --max-time 10 --request POST \
          --output /dev/null \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header 'mcp-session-id: wrong-session' \
          --header 'mcp-protocol-version: 2025-06-18' \
          --data-binary "@$TMPDIR/notification.json" \
          http://127.0.0.1:8765/mcp
        expect_contract_rejection missing-protocol ${fakeTools}/bin/curl \
          --silent --show-error --fail-with-body --max-time 10 --request POST \
          --output /dev/null \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header 'mcp-session-id: fixture-session' \
          --data-binary "@$TMPDIR/notification.json" \
          http://127.0.0.1:8765/mcp
        expect_contract_rejection wrong-protocol ${fakeTools}/bin/curl \
          --silent --show-error --fail-with-body --max-time 10 --request POST \
          --output /dev/null \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header 'mcp-session-id: fixture-session' \
          --header 'mcp-protocol-version: 2024-11-05' \
          --data-binary "@$TMPDIR/notification.json" \
          http://127.0.0.1:8765/mcp
        expect_contract_rejection wrong-args ${fakeTools}/bin/curl \
          --silent --show-error --fail-with-body --max-time 10 --request POST \
          --dump-header "$TMPDIR/wrong-args.headers" \
          --output "$TMPDIR/wrong-args.response" \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header 'mcp-session-id: fixture-session' \
          --header 'mcp-protocol-version: 2025-06-18' \
          --data-binary "@$TMPDIR/wrong-args.json" \
          http://127.0.0.1:8765/mcp
        expect_contract_rejection wrong-timeout ${fakeTools}/bin/curl \
          --silent --show-error --fail-with-body --max-time 99 --request POST \
          --dump-header "$TMPDIR/wrong-timeout.headers" \
          --output "$TMPDIR/wrong-timeout.response" \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header 'mcp-session-id: fixture-session' \
          --header 'mcp-protocol-version: 2025-06-18' \
          --data-binary "@$TMPDIR/call.json" \
          http://127.0.0.1:8765/mcp
        expect_contract_rejection duplicate-timeout ${fakeTools}/bin/curl \
          --silent --show-error --fail-with-body --max-time 10 --max-time 10 --request POST \
          --dump-header "$TMPDIR/duplicate-timeout.headers" \
          --output "$TMPDIR/duplicate-timeout.response" \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header 'mcp-session-id: fixture-session' \
          --header 'mcp-protocol-version: 2025-06-18' \
          --data-binary "@$TMPDIR/call.json" \
          http://127.0.0.1:8765/mcp
        expect_contract_rejection unknown-url ${fakeTools}/bin/curl \
          --silent --show-error --fail-with-body --max-time 10 --request GET \
          --output /dev/null http://127.0.0.1:9999/unknown
        expect_contract_rejection unknown-target ${fakeTools}/bin/curl \
          --silent --show-error --fail-with-body --max-time 10 --request POST \
          --dump-header "$TMPDIR/unknown-target.headers" \
          --output "$TMPDIR/unknown-target.response" \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header 'mcp-session-id: fixture-session' \
          --header 'mcp-protocol-version: 2025-06-18' \
          --data-binary "@$TMPDIR/unknown-target.json" \
          http://127.0.0.1:8765/mcp

        ((test_failures == 0))

        touch "$out"
      '';
}
