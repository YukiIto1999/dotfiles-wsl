{ pkgs, lib, ... }:

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
    managedSpaceDoctor
    numericNoiseDoctor
    numericOversizeDoctor
    passDoctor
    poisonDoctor
    releaseDirectoryDoctor
    releaseEscapeDoctor
    releaseMissingLinkFixtures
    releaseNonExecutableDoctor
    restartThresholdFailureDoctor
    rosterFailureOnlyDoctor
    rosterOmitDoctor
    timeoutDoctor
    warningDoctor
    ;
  inherit (base.support) mkRow;
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
            {id:"fixture/release-tree",status:"pass"},
            {id:"fixture/deployed-path",status:"pass"},
            {id:"fixture/path-metadata",status:"pass"},
            {id:"fixture/managed-roots",status:"pass"},
            {id:"fixture/systemd-service",status:"pass"},
            {id:"fixture/systemd-socket",status:"pass"},
            {id:"fixture/systemd-timer",status:"pass"},
            {id:"fixture/restart-service",status:"pass"},
            {id:"fixture/restart-container",status:"pass"},
            {id:"fixture/filesystem",status:"pass"},
            {id:"fixture/numeric",status:"pass"},
            {id:"fixture/swap",status:"pass"},
            {id:"fixture/journal",status:"pass"},
            {id:"fixture/container-image",status:"pass"},
            {id:"fixture/http-health",status:"pass"},
            {id:"fixture/protocol",status:"pass"}
          ]
          and .warnings == []
          and .failures == []
          and .resources == {
            fixtureFilesystem:{usedPercent:10},
            fixtureNumeric:{freePercent:20},
            fixtureJournal:{bytes:1024},
            managedRoots:[{path:"/fixture/root-ok",bytes:42}],
            fixtureProtocol:{state:"ok"},
            serviceRestarts:[{unit:"service-ok.service",count:0}],
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

        set +e
        failure_output=$(${lib.getExe failureDoctor} --json)
        failure_status=$?
        set -e
        test "$failure_status" -eq 1
        jq -e '
          (.checks | length) == 19
          and all(.checks[]; .status == "fail")
          and (.failures | length) == 19
          and .warnings == []
          and .resources.managedRoots == [{path:"/fixture/root-ok",bytes:42}]
          and .resources.serviceRestarts == []
          and .resources.containerRestarts == []
          and ([.failures[].id] | index("fixture/normalized-fallback")) == null
          and ([.failures[].id] | index("fixture/protocol")) != null
        ' <<<"$failure_output" >/dev/null

        warning_output=$(${lib.getExe warningDoctor} --json)
        jq -e '
          (.checks | length) == 4
          and all(.checks[]; .status == "warn")
          and (.warnings | length) == 4
          and .failures == []
          and .resources.serviceRestarts == [{unit:"service-warn.service",count:5}]
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
            serviceRestarts:[{unit:"service-fail.service",count:20}],
            containerRestarts:[]
          }
        ' <<<"$restart_threshold_failure_output" >/dev/null

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

        filesystem_free_output=$(${lib.getExe filesystemFreeDoctor} --json)
        jq -e '
          .checks == [{id:"fixture/filesystem-free",status:"pass"}]
          and .warnings == []
          and .failures == []
          and .resources.fixtureFilesystemFree == {freePercent:90}
        ' <<<"$filesystem_free_output" >/dev/null

        managed_space_output=$(${lib.getExe managedSpaceDoctor} --json)
        jq -e '
          .checks == [{id:"fixture/managed-space",status:"pass"}]
          and .warnings == []
          and .failures == []
          and .resources.managedSpace == [{path:"/fixture/root with space",bytes:42}]
        ' <<<"$managed_space_output" >/dev/null

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

        set +e
        release_escape_output=$(${lib.getExe releaseEscapeDoctor} --json)
        release_escape_status=$?
        set -e
        test "$release_escape_status" -eq 1
        jq -e '
          .checks == [{id:"fixture/release-escape",status:"fail"}]
          and .failures == [{id:"fixture/release-escape",message:"fixture release-tree failed"}]
        ' <<<"$release_escape_output" >/dev/null

        for release_invalid in \
          ${lib.getExe releaseDirectoryDoctor} \
          ${lib.getExe releaseNonExecutableDoctor}; do
          set +e
          release_invalid_output=$("$release_invalid" --json)
          release_invalid_status=$?
          set -e
          test "$release_invalid_status" -eq 1
          jq -e '
            (.checks | length) == 1
            and .checks[0].status == "fail"
            and (.failures | length) == 1
          ' <<<"$release_invalid_output" >/dev/null
        done

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: fixture: ''
            release_observation=release-missing-${name}.json
            release_scratch=release-missing-${name}-scratch
            mkdir "$release_scratch"
            printf '%s\n' ${lib.escapeShellArg (builtins.toJSON (mkRow "fixture/release-missing-${name}" fixture.observation))} >"$release_observation"
            set +e
            ${lib.getExe fixture.doctor.probe} \
              "$release_observation" "$release_scratch" >release-missing-${name}.out
            release_missing_status=$?
            set -e
            test "$release_missing_status" -eq 0
            jq -e '
              .checks == [{id:${builtins.toJSON fixture.observation.checkId},status:"fail"}]
              and .warnings == []
              and .failures == [{
                id:${builtins.toJSON fixture.observation.checkId},
                message:${builtins.toJSON fixture.observation.failureMessage}
              }]
              and .resources == []
              and .restart == null
            ' release-missing-${name}.out >/dev/null
          '') releaseMissingLinkFixtures
        )}

        set +e
        timeout_output=$(${lib.getExe timeoutDoctor} --json)
        timeout_status=$?
        set -e
        test "$timeout_status" -eq 1
        jq -e '
          .checks == [{id:"fixture/timeout-fallback",status:"fail"}]
          and .failures == [{id:"fixture/timeout-fallback",message:"fixture normalized-fallback failed"}]
        ' <<<"$timeout_output" >/dev/null
        test -s orphan.pid
        orphan_pid=$(<orphan.pid)
        ! kill -0 "$orphan_pid" 2>/dev/null

        set +e
        ${lib.getExe passDoctor} --json extra >/dev/null 2>&1
        usage_status=$?
        set -e
        test "$usage_status" -eq 2
        ${lib.getExe passDoctor} --help >/dev/null

        touch "$out"
      '';

}
