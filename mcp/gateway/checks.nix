{
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  variantConfig,
  ...
}:

let
  agentgateway = pkgs.callPackage ../package/agentgateway.nix { };
  fixtureProbes = {
    alpha = {
      tool = "ping";
      args = {
        value = "alpha";
      };
      timeout = 2;
    };
    zeta = {
      tool = "status";
      args = { };
      timeout = 1;
    };
  };
  fakeCurl = pkgs.writeShellApplication {
    name = "curl";
    excludeShellChecks = [ "SC2016" ];
    text =
      builtins.replaceStrings
        [
          "@jqCommand@"
          "@sleepCommand@"
          "@touchCommand@"
        ]
        [
          (lib.escapeShellArg (lib.getExe pkgs.jq))
          (lib.escapeShellArg "${pkgs.coreutils}/bin/sleep")
          (lib.escapeShellArg "${pkgs.coreutils}/bin/touch")
        ]
        (builtins.readFile ./fixtures/observer/fake-curl.sh);
  };
  fakeJq = pkgs.writeShellApplication {
    name = "jq";
    text = ''
      set -euo pipefail

      if [[ -n ''${MCP_OBSERVER_JQ_FAIL_MARKER-} && -e $MCP_OBSERVER_JQ_FAIL_MARKER ]]; then
        exit 70
      fi

      exec ${lib.escapeShellArg (lib.getExe pkgs.jq)} "$@"
    '';
  };
  fixtureObserver = pkgs.callPackage ./impl/observer-package.nix {
    name = "fixture-mcp-gateway-observer";
    gatewayUrl = "http://127.0.0.1:18765/mcp";
    probes = fixtureProbes;
    tools = {
      curl = lib.getExe fakeCurl;
      jq = lib.getExe pkgs.jq;
      mktemp = "${pkgs.coreutils}/bin/mktemp";
      rm = "${pkgs.coreutils}/bin/rm";
    };
  };
  crashObserver = pkgs.callPackage ./impl/observer-package.nix {
    name = "fixture-crash-mcp-gateway-observer";
    gatewayUrl = "http://127.0.0.1:18765/mcp";
    probes = fixtureProbes;
    tools = {
      curl = lib.getExe fakeCurl;
      jq = "${pkgs.coreutils}/bin/false";
      mktemp = "${pkgs.coreutils}/bin/mktemp";
      rm = "${pkgs.coreutils}/bin/rm";
    };
  };
  postSessionCrashObserver = pkgs.callPackage ./impl/observer-package.nix {
    name = "fixture-post-session-crash-mcp-gateway-observer";
    gatewayUrl = "http://127.0.0.1:18765/mcp";
    probes = fixtureProbes;
    tools = {
      curl = lib.getExe fakeCurl;
      jq = lib.getExe fakeJq;
      mktemp = "${pkgs.coreutils}/bin/mktemp";
      rm = "${pkgs.coreutils}/bin/rm";
    };
  };
  artifact = hostConfig.dotfiles.artifacts."mcp/gateway/default/config";
  expected = builtins.fromJSON (builtins.readFile ./fixtures/contract.json);
  gateway = hostConfig.dotfiles.mcp.gateway;
  fronts = hostConfig.dotfiles.mcp.fronts;
  service = hostConfig.systemd.services.${gateway.service};
  inherit (service) serviceConfig;
  frontServices = map (front: front.service) (builtins.attrValues fronts);
  deployedConfig = hostConfig.environment.etc."${gateway.runtimeDirectory}/config.yaml";
  sourceArtifacts = builtins.filter (entry: entry.source == gateway.source) (
    builtins.attrValues hostConfig.dotfiles.artifacts
  );
  variantGateway = variantConfig.dotfiles.mcp.gateway;
  variantArtifact = variantConfig.dotfiles.artifacts."mcp/gateway/default/config";
  variantDeployedConfig =
    variantConfig.environment.etc."${variantGateway.runtimeDirectory}/config.yaml";
  deployedPath = "/etc/${gateway.runtimeDirectory}/config.yaml";
  variantDeployedPath = "/etc/${variantGateway.runtimeDirectory}/config.yaml";
  expectedVariant = expected // {
    port = 9876;
    url = "http://127.0.0.1:9876/mcp";
  };

  dependencyFree =
    candidate:
    lib.all (dependencies: lib.intersectLists frontServices dependencies == [ ]) [
      candidate.after
      candidate.requires
      candidate.wants
    ];
  firstFrontService = builtins.head frontServices;
  dependencyMutations = [
    (service // { after = service.after ++ [ firstFrontService ]; })
    (service // { requires = [ firstFrontService ]; })
    (service // { wants = [ firstFrontService ]; })
  ];

  lifecyclePatch = builtins.concatStringsSep "\n" (
    map builtins.readFile [
      ../package/agentgateway/mcp-downstream-lifecycle.patch
      ../package/agentgateway/mcp-loopback-bind.patch
    ]
  );
  filter = builtins.head agentgateway.checkFlags;
  definedTests = builtins.filter (match: match != null) (
    map (line: builtins.match "\\+[[:space:]]*(async )?fn (${filter}[a-z_]+)\\(.*" line) (
      lib.splitString "\n" lifecyclePatch
    )
  );
in
{
  mcp-gateway-observer =
    assert fixtureObserver.meta.mainProgram == "fixture-mcp-gateway-observer";
    assert fixtureObserver.dotfilesObservationCommandKind == "normalized-protocol";
    assert
      fixtureObserver.dotfilesObservationContract == {
        envelopeVersion = 1;
        allowedOutcomeIds = [
          "mcp-session"
          "mcp-tools"
          "mcp-target/alpha"
          "mcp-target/zeta"
        ];
        requiredOutcomeIds = [ "mcp-session" ];
        requiredResourceKeys = [ ];
        gatewayTimeout = 2;
        outerTimeout = 10;
      };
    pkgs.runCommandLocal "check-mcp-gateway-observer-contract"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
      }
      ''
            set -euo pipefail

            test -x ${lib.getExe fixtureObserver}

            run_case() {
              local name=$1
              local expected=$2
              local output status
              set +e
              output=$(MCP_OBSERVER_CASE="$name" ${lib.getExe fixtureObserver} 2>"$TMPDIR/$name.stderr")
              status=$?
              set -e
              if [[ $status -ne 0 ]]; then
                printf '%s unexpectedly exited %s\n' "$name" "$status" >&2
                return 1
              fi
              jq -e --argjson expected "$expected" '
                .schemaVersion == 1
                and .resources == []
                and .outcomes == $expected
                and (keys | sort) == ["outcomes", "resources", "schemaVersion"]
              ' >/dev/null <<<"$output" || {
                printf '%s emitted an unexpected envelope:\n%s\n' "$name" "$output" >&2
                return 1
              }
              test ! -s "$TMPDIR/$name.stderr"
            }

            all_pass='[
              {"id":"mcp-session","status":"pass","message":"MCP session lifecycle passed"},
              {"id":"mcp-tools","status":"pass","message":"MCP tools/list covers every target probe"},
              {"id":"mcp-target/alpha","status":"pass","message":"MCP tools/call passed"},
              {"id":"mcp-target/zeta","status":"pass","message":"MCP tools/call passed"}
            ]'
            run_case healthy-json "$all_pass"
            run_case healthy-sse "$all_pass"
            run_case args-timeout "$all_pass"
            run_case delete-405 "$all_pass"
            run_case network-error '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize request failed"}
            ]'
            run_case missing-session '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize did not return exactly one session ID"}
            ]'
            run_case duplicate-session '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize did not return exactly one session ID"}
            ]'
            run_case empty-session '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize did not return exactly one session ID"}
            ]'
            run_case init-error '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize response is invalid"}
            ]'
            run_case invalid-protocol '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize response is invalid"}
            ]'
            run_case init-missing-capabilities '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize response is invalid"}
            ]'
            run_case init-missing-server-info '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize response is invalid"}
            ]'
            run_case init-missing-server-name '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize response is invalid"}
            ]'
            run_case init-missing-server-version '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize response is invalid"}
            ]'
            run_case invalid-content-type '[
              {"id":"mcp-session","status":"fail","message":"MCP initialize response is invalid"}
            ]'
          run_case notification-error '[
            {"id":"mcp-session","status":"fail","message":"MCP initialized notification failed"}
          ]'
          for notification_case in \
            notification-json-error \
            notification-body \
            notification-content-type \
            notification-redirect; do
            run_case "$notification_case" '[
              {"id":"mcp-session","status":"fail","message":"MCP initialized notification failed"}
            ]'
          done
          notification_delete_marker="$TMPDIR/notification-delete"
          notification_output=$(MCP_OBSERVER_CASE=notification-error \
            MCP_OBSERVER_DELETE_MARKER="$notification_delete_marker" \
            ${lib.getExe fixtureObserver})
          test -e "$notification_delete_marker"
          jq -e '.outcomes == [{id:"mcp-session",status:"fail",message:"MCP initialized notification failed"}]' \
            >/dev/null <<<"$notification_output"
          for initialize_case in \
            init-error \
            invalid-protocol \
            init-missing-capabilities \
            init-missing-server-info \
            init-missing-server-name \
            init-missing-server-version; do
            initialize_delete_marker="$TMPDIR/$initialize_case-delete"
            initialize_output=$(MCP_OBSERVER_CASE="$initialize_case" \
              MCP_OBSERVER_DELETE_MARKER="$initialize_delete_marker" \
              ${lib.getExe fixtureObserver})
            test -e "$initialize_delete_marker"
            jq -e '.outcomes == [{id:"mcp-session",status:"fail",message:"MCP initialize response is invalid"}]' \
              >/dev/null <<<"$initialize_output"
          done
            run_case tools-missing '[
              {"id":"mcp-session","status":"pass","message":"MCP session lifecycle passed"},
              {"id":"mcp-tools","status":"fail","message":"MCP tools/list response does not cover every target probe"},
              {"id":"mcp-target/alpha","status":"pass","message":"MCP tools/call passed"},
              {"id":"mcp-target/zeta","status":"pass","message":"MCP tools/call passed"}
            ]'
            run_case tools-wrong-exact '[
              {"id":"mcp-session","status":"pass","message":"MCP session lifecycle passed"},
              {"id":"mcp-tools","status":"fail","message":"MCP tools/list response does not cover every target probe"},
              {"id":"mcp-target/alpha","status":"pass","message":"MCP tools/call passed"},
              {"id":"mcp-target/zeta","status":"pass","message":"MCP tools/call passed"}
            ]'
            run_case target-error '[
              {"id":"mcp-session","status":"pass","message":"MCP session lifecycle passed"},
              {"id":"mcp-tools","status":"pass","message":"MCP tools/list covers every target probe"},
              {"id":"mcp-target/alpha","status":"fail","message":"MCP tools/call failed or returned an MCP error"},
              {"id":"mcp-target/zeta","status":"pass","message":"MCP tools/call passed"}
            ]'
            run_case target-is-error '[
              {"id":"mcp-session","status":"pass","message":"MCP session lifecycle passed"},
              {"id":"mcp-tools","status":"pass","message":"MCP tools/list covers every target probe"},
              {"id":"mcp-target/alpha","status":"fail","message":"MCP tools/call failed or returned an MCP error"},
              {"id":"mcp-target/zeta","status":"pass","message":"MCP tools/call passed"}
            ]'
            run_case target-missing-content '[
              {"id":"mcp-session","status":"pass","message":"MCP session lifecycle passed"},
              {"id":"mcp-tools","status":"pass","message":"MCP tools/list covers every target probe"},
              {"id":"mcp-target/alpha","status":"fail","message":"MCP tools/call failed or returned an MCP error"},
              {"id":"mcp-target/zeta","status":"pass","message":"MCP tools/call passed"}
            ]'
            run_case target-invalid-is-error '[
              {"id":"mcp-session","status":"pass","message":"MCP session lifecycle passed"},
              {"id":"mcp-tools","status":"pass","message":"MCP tools/list covers every target probe"},
              {"id":"mcp-target/alpha","status":"fail","message":"MCP tools/call failed or returned an MCP error"},
              {"id":"mcp-target/zeta","status":"pass","message":"MCP tools/call passed"}
            ]'
            for content_case in \
              target-non-object-content \
              target-unsupported-content \
              target-missing-content-type \
              target-text-missing-field \
              target-image-missing-field \
              target-image-missing-data \
              target-audio-missing-field \
              target-audio-missing-mime-type \
              target-resource-link-missing-field \
              target-resource-link-missing-uri \
              target-resource-missing-field \
              target-resource-missing-object \
              target-resource-missing-uri; do
              run_case "$content_case" '[
                {"id":"mcp-session","status":"pass","message":"MCP session lifecycle passed"},
                {"id":"mcp-tools","status":"pass","message":"MCP tools/list covers every target probe"},
                {"id":"mcp-target/alpha","status":"fail","message":"MCP tools/call failed or returned an MCP error"},
                {"id":"mcp-target/zeta","status":"pass","message":"MCP tools/call passed"}
              ]'
            done
            run_case delete-failure '[
              {"id":"mcp-session","status":"fail","message":"MCP session DELETE failed"},
              {"id":"mcp-tools","status":"pass","message":"MCP tools/list covers every target probe"},
              {"id":"mcp-target/alpha","status":"pass","message":"MCP tools/call passed"},
              {"id":"mcp-target/zeta","status":"pass","message":"MCP tools/call passed"}
            ]'

            secret='fixture-super-secret-value'
            secret_output=$(MCP_OBSERVER_CASE=secret-network MCP_OBSERVER_SECRET="$secret" \
              ${lib.getExe fixtureObserver} 2>"$TMPDIR/secret.stderr")
            ! grep -F -- "$secret" <<<"$secret_output"
            ! grep -F -- "$secret" "$TMPDIR/secret.stderr"
            jq -e '.outcomes == [{id:"mcp-session",status:"fail",message:"MCP initialize request failed"}]' \
              >/dev/null <<<"$secret_output"

            secret_body_output=$(MCP_OBSERVER_CASE=secret-body MCP_OBSERVER_SECRET="$secret" \
              ${lib.getExe fixtureObserver} 2>"$TMPDIR/secret-body.stderr")
            ! grep -F -- "$secret" <<<"$secret_body_output"
            ! grep -F -- "$secret" "$TMPDIR/secret-body.stderr"
        jq -e '.outcomes == [{id:"mcp-session",status:"fail",message:"MCP initialize response is invalid"}]' \
          >/dev/null <<<"$secret_body_output"

        secret_session_output=$(MCP_OBSERVER_CASE=secret-session MCP_OBSERVER_SECRET="$secret" \
          ${lib.getExe fixtureObserver} 2>"$TMPDIR/secret-session.stderr")
        ! grep -F -- "$secret" <<<"$secret_session_output"
        ! grep -F -- "$secret" "$TMPDIR/secret-session.stderr"
        jq -e '.outcomes == [{id:"mcp-session",status:"fail",message:"MCP initialized notification failed"}]' \
          >/dev/null <<<"$secret_session_output"

        argv_secret='fixture-argv-secret-value'
        argv_pid_file="$TMPDIR/argv-secret.pid"
        argv_release_file="$TMPDIR/argv-secret.release"
        MCP_OBSERVER_CASE=argv-secret \
          MCP_OBSERVER_SECRET="$argv_secret" \
          MCP_OBSERVER_CURL_PID_FILE="$argv_pid_file" \
          MCP_OBSERVER_CURL_RELEASE_FILE="$argv_release_file" \
          ${lib.getExe fixtureObserver} >"$TMPDIR/argv-secret.output" &
        argv_observer_pid=$!
        for _ in {1..500}; do
          [[ -s $argv_pid_file ]] && break
          sleep 0.02
        done
        test -s "$argv_pid_file"
        argv_curl_pid=$(<"$argv_pid_file")
        mapfile -d $'\0' -t argv_parts <"/proc/$argv_curl_pid/cmdline"
        ! printf '%s\n' "''${argv_parts[@]}" | grep -F -- "$argv_secret"
        session_header_path=
        for argv_part in "''${argv_parts[@]}"; do
          [[ $argv_part == @*/session.headers ]] && session_header_path=''${argv_part#@}
        done
        test -n "$session_header_path"
        test "$(stat -c '%a' "$session_header_path")" = 600
        touch "$argv_release_file"
        wait "$argv_observer_pid"
        jq -e --argjson expected "$all_pass" '.outcomes == $expected' \
          "$TMPDIR/argv-secret.output" >/dev/null

            set +e
            crash_output=$(${lib.getExe crashObserver} 2>"$TMPDIR/crash.stderr")
            crash_status=$?
            set -e
            test "$crash_status" -ne 0
            ! jq -e . >/dev/null 2>&1 <<<"$crash_output"

            set +e
            timeout_output=$(MCP_OBSERVER_CASE=observer-timeout \
              timeout --signal=TERM --kill-after=1 1 ${lib.getExe fixtureObserver} \
              2>"$TMPDIR/timeout.stderr")
            timeout_status=$?
            set -e
            test "$timeout_status" -eq 124
            ! jq -e . >/dev/null 2>&1 <<<"$timeout_output"

            post_session_timeout_marker="$TMPDIR/post-session-timeout"
            timeout_delete_marker="$TMPDIR/post-session-timeout-delete"
            set +e
            MCP_OBSERVER_CASE=post-session-timeout \
              MCP_OBSERVER_POST_SESSION_MARKER="$post_session_timeout_marker" \
              MCP_OBSERVER_DELETE_MARKER="$timeout_delete_marker" \
              timeout --signal=TERM --kill-after=5 1 ${lib.getExe fixtureObserver} \
              >"$TMPDIR/post-session-timeout.output" 2>"$TMPDIR/post-session-timeout.stderr"
            post_session_timeout_status=$?
            set -e
            [[ $post_session_timeout_status -eq 124 ]] || {
              printf 'post-session timeout exited %s, expected 124\n' "$post_session_timeout_status" >&2
              exit 1
            }
            [[ -e $post_session_timeout_marker ]] || {
              printf 'post-session timeout did not reach the initialized notification\n' >&2
              exit 1
            }
            [[ -e $timeout_delete_marker ]] || {
              printf 'post-session timeout did not DELETE the acquired session\n' >&2
              exit 1
            }

            post_session_term_marker="$TMPDIR/post-session-term"
            term_delete_marker="$TMPDIR/post-session-term-delete"
            MCP_OBSERVER_CASE=post-session-term \
              MCP_OBSERVER_POST_SESSION_MARKER="$post_session_term_marker" \
              MCP_OBSERVER_DELETE_MARKER="$term_delete_marker" \
              ${lib.getExe fixtureObserver} >"$TMPDIR/post-session-term.output" \
              2>"$TMPDIR/post-session-term.stderr" &
            term_observer_pid=$!
            for _ in {1..100}; do
              [[ -e $post_session_term_marker ]] && break
              sleep 0.02
            done
            [[ -e $post_session_term_marker ]] || {
              printf 'TERM case did not reach the initialized notification\n' >&2
              exit 1
            }
            kill -TERM "$term_observer_pid"
            set +e
            wait "$term_observer_pid"
            term_status=$?
            set -e
            [[ $term_status -eq 143 ]] || {
              printf 'TERM case exited %s, expected 143\n' "$term_status" >&2
              exit 1
            }
            [[ -e $term_delete_marker ]] || {
              printf 'TERM case did not DELETE the acquired session\n' >&2
              exit 1
            }

            jq_fail_marker="$TMPDIR/post-session-jq-fail"
            jq_delete_marker="$TMPDIR/post-session-jq-delete"
            set +e
            MCP_OBSERVER_CASE=post-session-jq-error \
              MCP_OBSERVER_JQ_FAIL_MARKER="$jq_fail_marker" \
              MCP_OBSERVER_DELETE_MARKER="$jq_delete_marker" \
              ${lib.getExe postSessionCrashObserver} >"$TMPDIR/post-session-jq.output" \
              2>"$TMPDIR/post-session-jq.stderr"
            jq_status=$?
            set -e
            [[ $jq_status -ne 0 ]] || {
              printf 'post-session jq failure unexpectedly exited zero\n' >&2
              exit 1
            }
            [[ -e $jq_fail_marker ]] || {
              printf 'post-session jq case did not arm the failure marker\n' >&2
              exit 1
            }
            [[ -e $jq_delete_marker ]] || {
              printf 'post-session jq failure did not DELETE the acquired session\n' >&2
              exit 1
            }

        parallel_root="$TMPDIR/parallel"
        mkdir "$parallel_root"
        parallel_output=$(MCP_OBSERVER_CASE=parallel MCP_OBSERVER_PARALLEL_ROOT="$parallel_root" \
          ${lib.getExe fixtureObserver})
            jq -e --argjson expected "$all_pass" '.outcomes == $expected' >/dev/null <<<"$parallel_output"

            touch "$out"
      '';

  gateway-front-contract =
    assert fronts != { };
    assert gateway.targets == expected.targets;
    assert gateway.targets == builtins.attrNames fronts;
    assert lib.all (front: front.url == "http://127.0.0.1:${toString front.port}/mcp") (
      builtins.attrValues fronts
    );
    assert lib.all (front: hostConfig.systemd.services ? ${front.service}) (builtins.attrValues fronts);
    assert dependencyFree service;
    assert lib.all (candidate: !(dependencyFree candidate)) dependencyMutations;
    pkgs.runCommandLocal "check-gateway-front-contract" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      set -euo pipefail

      yq -r '[.binds[].listeners[].routes[].backends[].mcp.targets[] | .name + " " + .mcp.host] | sort | .[]' \
        ${gateway.source} > actual-targets
      printf '%s' ${
        lib.escapeShellArg (
          lib.concatStringsSep "\n" (
            lib.sort builtins.lessThan (lib.mapAttrsToList (name: front: "${name} ${front.url}") fronts)
          )
        )
      } > expected-targets
      printf '\n' >> expected-targets
      diff --unified expected-targets actual-targets
      test "$(yq -r '[.binds[].listeners[].routes[].backends[].mcp.targets[] | select(.stdio)] | length' ${gateway.source})" = 0
      touch $out
    '';

  gateway-artifact-contract =
    let
      projection = {
        inherit (gateway)
          id
          port
          runtimeDirectory
          service
          targets
          url
          ;
      };
    in
    assert expected.targets != [ ];
    assert
      builtins.attrNames gateway == [
        "id"
        "port"
        "runtimeDirectory"
        "service"
        "source"
        "targets"
        "url"
      ];
    assert hostOptions.dotfiles.mcp.gateway.id.readOnly;
    assert !(hostOptions.dotfiles.mcp.gateway.port.readOnly or false);
    assert hostOptions.dotfiles.mcp.gateway.url.readOnly;
    assert hostOptions.dotfiles.mcp.gateway.service.readOnly;
    assert hostOptions.dotfiles.mcp.gateway.runtimeDirectory.readOnly;
    assert hostOptions.dotfiles.mcp.gateway.source.readOnly;
    assert hostOptions.dotfiles.mcp.gateway.source.type.name == "path";
    assert hostOptions.dotfiles.mcp.gateway.targets.readOnly;
    assert projection == expected;
    assert
      {
        inherit (variantGateway)
          id
          port
          runtimeDirectory
          service
          targets
          url
          ;
      } == expectedVariant;
    assert artifact.format == "yaml";
    assert artifact.deployedAt == deployedPath;
    assert artifact.source == gateway.source;
    assert
      hostConfig.dotfiles.observations."artifacts/mcp/gateway/default/config" == {
        kind = "deployed-path";
        checkId = "artifact/mcp/gateway/default/config";
        resourceKey = null;
        timeoutSeconds = 10;
        failureMessage = "${deployedPath} does not match ${toString gateway.source}";
        source = toString gateway.source;
        destination = deployedPath;
        acceptedDestinationKinds = [
          "regular-file"
          "symlink"
        ];
      };
    assert deployedConfig.source == gateway.source;
    assert builtins.length sourceArtifacts == 1;
    assert variantGateway.source != gateway.source;
    assert variantArtifact.source == variantGateway.source;
    assert variantArtifact.deployedAt == variantDeployedPath;
    assert variantDeployedConfig.source == variantGateway.source;
    assert service.after == [ "network.target" ];
    assert service.requires == [ ];
    assert service.wants == [ ];
    assert serviceConfig.User == hostConfig.dotfiles.host.username;
    assert serviceConfig.Environment == [ "HOME=${hostConfig.dotfiles.host.homeDir}" ];
    assert serviceConfig.RuntimeDirectory == gateway.runtimeDirectory;
    assert serviceConfig.RuntimeDirectoryMode == "0700";
    assert serviceConfig.LimitNOFILE == "4096:4096";
    assert serviceConfig.MemoryMax == "2G";
    assert serviceConfig.IPAddressDeny == "any";
    assert serviceConfig.IPAddressAllow == "localhost";
    assert serviceConfig.Restart == "always";
    assert serviceConfig.RestartSec == "5s";
    pkgs.runCommandLocal "check-gateway-artifact-contract" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      set -euo pipefail

        ${agentgateway}/bin/agentgateway --validate-only -f ${gateway.source}
        ${agentgateway}/bin/agentgateway --validate-only -f ${variantGateway.source}
      test "$(yq -r '.config.mcp.sessionTtl' ${gateway.source})" = 1800s
      test "$(yq -r '.config.adminAddr' ${gateway.source})" = 127.0.0.1:15000
      test "$(yq -r '.config.statsAddr' ${gateway.source})" = 127.0.0.1:15020
      test "$(yq -r '.config.readinessAddr' ${gateway.source})" = 127.0.0.1:15021
        test "$(yq -r '.binds | length' ${gateway.source})" = 1
        test "$(yq -r '.binds[0].port' ${gateway.source})" = ${toString gateway.port}
        test "$(yq -r '.binds[0].port' ${variantGateway.source})" = ${toString variantGateway.port}
      test "$(yq -r '.binds[0].listeners | length' ${gateway.source})" = 1
      test "$(yq -r '.binds[0].listeners[0].routes[0].backends | length' ${gateway.source})" = 1
      test "$(yq -r '.binds[0].listeners[0].routes[0].backends[0].mcp.failureMode' ${gateway.source})" = failOpen
      test "$(yq -r '.binds[0].listeners[0].routes[0].policies.mcpAuthorization.rules | length' ${gateway.source})" = 1
      test "$(yq -r '.binds[0].listeners[0].routes[0].policies.mcpAuthorization.rules[0].deny' ${gateway.source})" = 'mcp.tool.name == "web_url_read"'
      touch $out
    '';

  agentgateway-session-lifecycle =
    assert builtins.length definedTests == 4;
    assert serviceConfig.ExecStart == "${agentgateway}/bin/agentgateway -f ${gateway.source}";
    agentgateway;
}
