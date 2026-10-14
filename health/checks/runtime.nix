{ pkgs, lib, ... }:
{
  source = [
    (
      let
        base = import ../fixtures/runtime-base.nix { inherit pkgs lib; };
        fragments = import ../fixtures/runtime-fragments.nix {
          inherit pkgs lib;
          inherit (base) support;
        };
        inherit (base)
          duplicateDoctor
          emptyNormalizedDoctor
          failureDoctor
          filesystemFreeDoctor
          invalidNormalizedDoctors
          killedProbeDoctor
          managerDoctors
          numericNoiseDoctor
          numericOversizeDoctor
          numericSetInvalidDoctors
          numericSetUsedDoctor
          poisonDoctor
          passDoctor
          restartThresholdFailureDoctor
          rosterFailureOnlyDoctor
          rosterOmitDoctor
          strayProcessDoctor
          termTimeoutDoctor
          timeoutDoctor
          timerStateDoctors
          unreadableProcessDoctor
          warningDoctor
          zramInvalidPathDoctor
          zramPathDoctor
          ;
        inherit (fragments)
          malformedFragmentDoctors
          restartFailureWithoutPayloadDoctor
          semanticFragmentFixtures
          ;
      in
      {
        doctor-runtime =
          pkgs.runCommandLocal "check-doctor-runtime"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.jq
              ];
            }
            ''
              set -euo pipefail

              pass_output=$(${lib.getExe passDoctor} --json)
              jq -e '
                (keys | sort) == ["checks","failures","resources","warnings"]
                and .checks == [
                  {id:"fixture/roster",status:"pass"},
                  {id:"fixture/path-match",status:"pass"},
                  {id:"fixture/command-version",status:"pass"},
                  {id:"fixture/deployed-path",status:"pass"},
                  {id:"fixture/path-metadata",status:"pass"},
                  {id:"fixture/systemd-service",status:"pass"},
                  {id:"fixture/systemd-socket",status:"pass"},
                  {id:"fixture/systemd-timer",status:"pass"},
                  {id:"fixture/timer-exit",status:"pass"},
                  {id:"fixture/restart-service",status:"pass"},
                  {id:"fixture/restart-container",status:"pass"},
                  {id:"fixture/filesystem",status:"pass"},
                  {id:"fixture/numeric",status:"pass"},
                  {id:"fixture/swap",status:"pass"},
                  {id:"fixture/journal",status:"pass"},
                  {id:"fixture/container-image",status:"pass"},
                  {id:"fixture/http-health",status:"pass"},
                  {id:"fixture/protocol",status:"pass"},
                  {id:"fixture/numeric-set/c",status:"pass"},
                  {id:"fixture/numeric-set/d",status:"pass"},
                  {id:"fixture/process-slice",status:"pass"}
                ]
                and .warnings == []
                and .failures == []
                and .resources == {
                  fixtureFilesystem:{usedPercent:10},
                  fixtureNumeric:{freePercent:20},
                  fixtureJournal:{bytes:1024},
                  fixtureProtocol:{state:"ok"},
                  fixtureNumericSet:[{name:"c",freePercent:20},{name:"d",freePercent:30}],
                  fixtureProcessSlice:{inside:3,outside:0},
                  serviceRestarts:[{manager:"system",unit:"service-ok.service",count:0}],
                  containerRestarts:[{container:"container-ok",count:0}],
                  fixtureSwap:{
                    totalBytes:8589934592,
                    zramDevices:1,
                    diskDevices:1,
                    minZramPriority:100,
                    maxDiskPriority:-2,
                    algorithms:["lzo-rle"]
                  }
                }
              ' <<<"$pass_output" >/dev/null
              zram_path_output=$(${lib.getExe zramPathDoctor} --json)
              jq -e '
                .checks == [{id:"fixture/swap-zram-path",status:"pass"}]
                and .warnings == []
                and .failures == []
                and .resources.fixtureSwap == {
                  totalBytes:8589934592,
                  zramDevices:1,
                  diskDevices:1,
                  minZramPriority:100,
                  maxDiskPriority:-2,
                  algorithms:["lzo-rle"]
                }
              ' <<<"$zram_path_output" >/dev/null
              set +e
              zram_invalid_path_output=$(${lib.getExe zramInvalidPathDoctor} --json)
              zram_invalid_path_status=$?
              set -e
              test "$zram_invalid_path_status" -eq 1
              jq -e '
                .checks == [{id:"fixture/swap-invalid-zram-path",status:"fail"}]
                and .warnings == []
                and .failures == [{
                  id:"fixture/swap-invalid-zram-path",
                  message:"fixture swap-invalid-zram-path failed"
                }]
                and .resources.fixtureSwap == {
                  totalBytes:8589934592,
                  zramDevices:0,
                  diskDevices:2,
                  minZramPriority:0,
                  maxDiskPriority:100,
                  algorithms:[]
                }
              ' <<<"$zram_invalid_path_output" >/dev/null

              set +e
              failure_output=$(${lib.getExe failureDoctor} --json)
              failure_status=$?
              set -e
              test "$failure_status" -eq 1
              jq -e '
                all(.checks[]; .status == "fail")
                and ([.failures[] | select(.id == "fixture/numeric-set/c" or .id == "fixture/numeric-set/d") | .message]
                  == ["free-percent crossed its fail threshold","free-percent crossed its fail threshold"])
                and .warnings == []
                and .resources.fixtureProcessSlice == {inside:0,outside:3}
                and .resources.serviceRestarts == []
                and .resources.containerRestarts == []
                and ([.failures[].id] | index("fixture/normalized-fallback")) == null
                and ([.failures[].id] | index("fixture/protocol")) != null
              ' <<<"$failure_output" >/dev/null

              warning_output=$(${lib.getExe warningDoctor} --json)
              jq -e '
                all(.checks[]; .status == "warn")
                and any(.warnings[]; . == {id:"fixture/warn-numeric-set/c",message:"free-percent crossed its warn threshold"})
                and .failures == []
                and .resources.serviceRestarts == [{manager:"system",unit:"service-warn.service",count:5}]
                and .resources.containerRestarts == [{container:"container-warn",count:5}]
              ' <<<"$warning_output" >/dev/null

              set +e
              restart_threshold_failure_output=$(${lib.getExe restartThresholdFailureDoctor} --json)
              restart_threshold_failure_status=$?
              set -e
              test "$restart_threshold_failure_status" -eq 1
              jq -e '
                .checks == [{id:"fixture/restart-threshold-failure",status:"fail"}]
                and .warnings == []
                and .failures == [{
                  id:"fixture/restart-threshold-failure",
                  message:"service-fail.service reached the restart failure threshold"
                }]
                and .resources == {
                  serviceRestarts:[{manager:"system",unit:"service-fail.service",count:20}],
                  containerRestarts:[]
                }
              ' <<<"$restart_threshold_failure_output" >/dev/null

              ${lib.concatStringsSep "\n" (
                lib.concatLists (
                  lib.mapAttrsToList (
                    caseName: managers:
                    lib.mapAttrsToList (
                      manager: fixture:
                      let
                        restartRows = lib.optional (fixture.expectation.restart == "pass") {
                          inherit manager;
                          unit = "shared-${caseName}.service";
                          count = 0;
                        };
                        anyFail = lib.any (status: status == "fail") (lib.attrValues fixture.expectation);
                      in
                      ''
                        set +e
                        manager_output=$(XDG_RUNTIME_DIR=/run/user/1000 ${lib.getExe fixture.doctor} --json)
                        manager_status=$?
                        set -e
                        test "$manager_status" -eq ${if anyFail then "1" else "0"}
                        jq -e \
                          --argjson expected ${lib.escapeShellArg (builtins.toJSON fixture.expectation)} \
                          --argjson restarts ${lib.escapeShellArg (builtins.toJSON restartRows)} '
                          ([.checks[] | {key: (.id | ltrimstr("fixture/${caseName}-${manager}-")), value: .status}] | from_entries) == $expected
                          and .warnings == []
                          and (.failures | length) == ([$expected[] | select(. == "fail")] | length)
                          and .resources.serviceRestarts == $restarts
                        ' <<<"$manager_output" >/dev/null
                      ''
                    ) managers
                  ) managerDoctors
                )
              )}
              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (state: fixture: ''
                  set +e
                  timer_state_output=$(XDG_RUNTIME_DIR=/run/user/1000 ${lib.getExe fixture.doctor} --json)
                  timer_state_status=$?
                  set -e
                  if [[ "$timer_state_status" != ${if fixture.status == "fail" then "1" else "0"} ]]; then
                    printf 'timer state ${state}: unexpected exit %s\n' "$timer_state_status" >&2
                    exit 1
                  fi
                  jq -e --arg expected ${lib.escapeShellArg fixture.status} '
                    .checks == [{id:"fixture/timer-state",status:$expected}]
                    and (.warnings | length) == (if $expected == "warn" then 1 else 0 end)
                    and (.failures | length) == (if $expected == "fail" then 1 else 0 end)
                  ' <<<"$timer_state_output" >/dev/null || {
                    printf 'timer state ${state}: %s\n' "$timer_state_output" >&2
                    exit 1
                  }
                '') timerStateDoctors
              )}

              set +e
              no_runtime_dir_output=$(env -u XDG_RUNTIME_DIR ${lib.getExe managerDoctors.healthy.user.doctor} --json)
              no_runtime_dir_status=$?
              set -e
              test "$no_runtime_dir_status" -eq 1
              jq -e '
                (.checks | length) == 3
                and all(.checks[]; .status == "fail")
                and (.failures | length) == 3
                and .resources.serviceRestarts == []
              ' <<<"$no_runtime_dir_output" >/dev/null

              set +e
              human_output=$(${lib.getExe warningDoctor} 2>&1)
              human_status=$?
              set -e
              test "$human_status" -eq 0
              grep -Fxq 'warn: fixture/warn-filesystem' <<<"$human_output"
              grep -Fxq 'warn: fixture/warn-container' <<<"$human_output"

              set +e
              duplicate_output=$(${lib.getExe duplicateDoctor} --json)
              duplicate_status=$?
              set -e
              test "$duplicate_status" -eq 1
              jq -e '
                .checks == [{id:"fixture/duplicate-fallback",status:"fail"}]
                and .failures == [{id:"fixture/duplicate-fallback",message:"fixture normalized-fallback failed"}]
              ' <<<"$duplicate_output" >/dev/null

              empty_normalized_output=$(${lib.getExe emptyNormalizedDoctor} --json)
              jq -e '
                .checks == []
                and .warnings == []
                and .failures == []
                and .resources == {
                  fixtureProtocol:{state:"disabled"},
                  serviceRestarts:[],
                  containerRestarts:[]
                }
              ' <<<"$empty_normalized_output" >/dev/null

              POISON_ENV=raw-secret-environment \
                ${lib.getExe poisonDoctor} --json > poison.out 2> poison.err
              jq -e '
                .checks == [{id:"fixture/protocol",status:"pass"}]
                and .failures == []
              ' poison.out >/dev/null
              ! grep -Fq raw-secret poison.out
              ! grep -Fq raw-secret poison.err

              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (name: doctor: ''
                  set +e
                  invalid_output=$(${lib.getExe doctor} --json 2>invalid-${name}.stderr)
                  invalid_status=$?
                  set -e
                  test "$invalid_status" -eq 1
                  jq -e '
                    .checks == [{id:"fixture/invalid-${name}",status:"fail"}]
                    and .failures == [{id:"fixture/invalid-${name}",message:"fixture normalized-fallback failed"}]
                    and .resources == {serviceRestarts:[],containerRestarts:[]}
                  ' <<<"$invalid_output" >/dev/null
                  ! grep -Fq raw-secret <<<"$invalid_output"
                  ! grep -Fq raw-secret invalid-${name}.stderr
                '') invalidNormalizedDoctors
              )}

              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (name: doctor: ''
                  set +e
                  malformed_output=$(${lib.getExe doctor} --json)
                  malformed_status=$?
                  set -e
                  test "$malformed_status" -eq 1
                  jq -e '
                    .checks == [{id:"fixture/malformed-${name}",status:"fail"}]
                    and .warnings == []
                    and .failures == [{
                      id:"fixture/malformed-${name}",
                      message:"fixture malformed ${name} failed"
                    }]
                    and .resources == {serviceRestarts:[],containerRestarts:[]}
                  ' <<<"$malformed_output" >/dev/null
                '') malformedFragmentDoctors
              )}

              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (_: fixture: ''
                  set +e
                  semantic_output=$(${lib.getExe fixture.doctor} --json)
                  semantic_status=$?
                  set -e
                  test "$semantic_status" -eq 1
                  jq -e '
                    .checks == [{id:${builtins.toJSON fixture.observation.checkId},status:"fail"}]
                    and .warnings == []
                    and .failures == [{
                      id:${builtins.toJSON fixture.observation.checkId},
                      message:${builtins.toJSON fixture.observation.failureMessage}
                    }]
                    and .resources == {serviceRestarts:[],containerRestarts:[]}
                  ' <<<"$semantic_output" >/dev/null
                '') semanticFragmentFixtures
              )}

              set +e
              restart_failure_without_payload_output=$(${lib.getExe restartFailureWithoutPayloadDoctor} --json)
              restart_failure_without_payload_status=$?
              set -e
              test "$restart_failure_without_payload_status" -eq 1
              jq -e '
                .checks == [{id:"fixture/restart-failure-without-payload",status:"fail"}]
                and .warnings == []
                and .failures == [{
                  id:"fixture/restart-failure-without-payload",
                  message:"restart failure without payload"
                }]
                and .resources == {serviceRestarts:[],containerRestarts:[]}
              ' <<<"$restart_failure_without_payload_output" >/dev/null

              set +e
              numeric_oversize_output=$(${lib.getExe numericOversizeDoctor} --json)
              numeric_oversize_status=$?
              set -e
              test "$numeric_oversize_status" -eq 1
              jq -e '
                .checks == [{id:"fixture/numeric-oversize",status:"fail"}]
                and .failures == [{id:"fixture/numeric-oversize",message:"fixture numeric failed"}]
              ' <<<"$numeric_oversize_output" >/dev/null

              set +e
              numeric_noise_output=$(${lib.getExe numericNoiseDoctor} --json)
              numeric_noise_status=$?
              set -e
              test "$numeric_noise_status" -eq 1
              jq -e '
                .checks == [{id:"fixture/numeric-noise",status:"fail"}]
                and .failures == [{id:"fixture/numeric-noise",message:"fixture numeric failed"}]
              ' <<<"$numeric_noise_output" >/dev/null

              set +e
              numeric_set_used_output=$(${lib.getExe numericSetUsedDoctor} --json)
              numeric_set_used_status=$?
              set -e
              test "$numeric_set_used_status" -eq 1
              jq -e '
                .checks == [
                  {id:"fixture/numeric-set-used/c",status:"warn"},
                  {id:"fixture/numeric-set-used/d",status:"fail"}
                ]
                and .warnings == [{id:"fixture/numeric-set-used/c",message:"used-percent crossed its warn threshold"}]
                and .failures == [{id:"fixture/numeric-set-used/d",message:"used-percent crossed its fail threshold"}]
                and .resources.fixtureNumericSetUsed == [{name:"c",usedPercent:90},{name:"d",usedPercent:96}]
              ' <<<"$numeric_set_used_output" >/dev/null

              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (name: doctor: ''
                  set +e
                  numeric_set_invalid_output=$(${lib.getExe doctor} --json)
                  numeric_set_invalid_status=$?
                  set -e
                  test "$numeric_set_invalid_status" -eq 1
                  jq -e '
                    .checks == [{id:"fixture/numeric-set-invalid-${name}",status:"fail"}]
                    and .warnings == []
                    and .failures == [{id:"fixture/numeric-set-invalid-${name}",message:"fixture numeric-set failed"}]
                    and .resources == {serviceRestarts:[],containerRestarts:[]}
                  ' <<<"$numeric_set_invalid_output" >/dev/null
                '') numericSetInvalidDoctors
              )}

              filesystem_free_output=$(${lib.getExe filesystemFreeDoctor} --json)
              jq -e '
                .checks == [{id:"fixture/filesystem-free",status:"pass"}]
                and .warnings == []
                and .failures == []
                and .resources.fixtureFilesystemFree == {freePercent:90}
              ' <<<"$filesystem_free_output" >/dev/null

              set +e
              stray_process_output=$(${lib.getExe strayProcessDoctor} --json)
              stray_process_status=$?
              set -e
              test "$stray_process_status" -eq 1
              jq -e '
                .checks == [{id:"fixture/stray-process",status:"fail"}]
                and .warnings == []
                and .failures == [{id:"fixture/stray-process",message:"fixture stray-process failed"}]
                and .resources.fixtureProcessSlice == {inside:1,outside:2}
              ' <<<"$stray_process_output" >/dev/null

              set +e
              unreadable_process_output=$(${lib.getExe unreadableProcessDoctor} --json)
              unreadable_process_status=$?
              set -e
              test "$unreadable_process_status" -eq 1
              jq -e '
                .checks == [{id:"fixture/unreadable-process",status:"fail"}]
                and .failures == [{id:"fixture/unreadable-process",message:"fixture unreadable-process failed"}]
                and .resources == {serviceRestarts:[],containerRestarts:[]}
              ' <<<"$unreadable_process_output" >/dev/null

              roster_omit_output=$(${lib.getExe rosterOmitDoctor} --json)
              jq -e '
                .checks == []
                and .warnings == []
                and .failures == []
                and .resources == {serviceRestarts:[],containerRestarts:[]}
              ' <<<"$roster_omit_output" >/dev/null

              set +e
              roster_failure_output=$(${lib.getExe rosterFailureOnlyDoctor} --json)
              roster_failure_status=$?
              set -e
              test "$roster_failure_status" -eq 1
              jq -e '
                .checks == [{id:"fixture/roster-failure-only",status:"fail"}]
                and .warnings == []
                and .failures == [{id:"fixture/roster-failure-only",message:"fixture roster failed"}]
              ' <<<"$roster_failure_output" >/dev/null


              timeout_output=$(${lib.getExe timeoutDoctor} --json)
              jq -e '
                .checks == [{id:"fixture/timeout-fallback",status:"warn"}]
                and .warnings == [{id:"fixture/timeout-fallback",message:"observation did not finish within 1s"}]
                and .failures == []
              ' <<<"$timeout_output" >/dev/null
              test -s orphan.pid
              orphan_pid=$(<orphan.pid)
              ! kill -0 "$orphan_pid" 2>/dev/null

              term_timeout_output=$(${lib.getExe termTimeoutDoctor} --json)
              jq -e '
                .checks == [{id:"fixture/term-timeout",status:"warn"}]
                and .warnings == [{id:"fixture/term-timeout",message:"observation did not finish within 1s"}]
                and .failures == []
              ' <<<"$term_timeout_output" >/dev/null

              set +e
              killed_probe_output=$(${lib.getExe killedProbeDoctor} --json)
              killed_probe_status=$?
              set -e
              test "$killed_probe_status" -eq 1
              jq -e '
                .checks == [{id:"fixture/killed-probe",status:"fail"}]
                and .warnings == []
                and .failures == [{id:"fixture/killed-probe",message:"fixture killed-probe failed"}]
              ' <<<"$killed_probe_output" >/dev/null

              set +e
              ${lib.getExe passDoctor} --json extra >/dev/null 2>&1
              usage_status=$?
              set -e
              test "$usage_status" -eq 2
              ${lib.getExe passDoctor} --help >/dev/null

              touch "$out"
            '';

      }
    )
  ];
}
