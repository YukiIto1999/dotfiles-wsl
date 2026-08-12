{
  pkgs,
  lib,
  hostConfig,
  helpers,
  ...
}:

let
  markedNormalizedCommand =
    (pkgs.writeShellApplication {
      name = "fixture-marked-normalized";
      text = "exit 0";
    }).overrideAttrs
      (old: {
        meta = (old.meta or { }) // {
          mainProgram = "fixture-marked-normalized";
        };
        passthru = (old.passthru or { }) // {
          dotfilesObservationCommandKind = "normalized-protocol";
        };
      });
  rosterContract = id: resourceKey: {
    kind = "roster";
    checkId = id;
    inherit resourceKey;
    timeoutSeconds = 10;
    failureMessage = "fixture roster failed";
    members = [ "fixture" ];
    minimumCount = 1;
    failureOnly = false;
  };
  normalizedContract = {
    kind = "normalized-protocol";
    checkId = "fixture/normalized";
    resourceKey = "normalizedResource";
    timeoutSeconds = 10;
    failureMessage = "fixture normalized failed";
    command = markedNormalizedCommand;
    allowedOutcomeIds = [ "fixture/normalized" ];
    requiredOutcomeIds = [ "fixture/normalized" ];
    requiredResourceKeys = [ "normalizedResource" ];
    envelopeVersion = 1;
  };
  evalRegistry =
    registry:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        helpers.observationRegistryModule
        ../../module.nix
        ../module.nix
        {
          options.environment.systemPackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
          };
          options.assertions = lib.mkOption {
            type = lib.types.listOf (
              lib.types.submodule {
                options = {
                  assertion = lib.mkOption { type = lib.types.bool; };
                  message = lib.mkOption { type = lib.types.str; };
                };
              }
            );
            default = [ ];
          };
          config.dotfiles.observations = registry;
        }
      ];
    };
  assertionsHold =
    registry:
    let
      evaluation = evalRegistry registry;
      forced = builtins.tryEval (
        builtins.deepSeq (
          map (assertion: assertion.assertion) evaluation.config.assertions
          ++ [ evaluation.config.dotfiles.commands.doctor.drvPath ]
        ) true
      );
    in
    forced.success
    && forced.value
    && lib.all (assertion: assertion.assertion) evaluation.config.assertions;
  assertionBase = {
    "fixture/one" = rosterContract "fixture/one" null;
    "fixture/two" = rosterContract "fixture/two" null;
    "fixture/normalized" = normalizedContract;
  };
  invalidAssertionRegistries = [
    (
      assertionBase
      // {
        "fixture/one" = rosterContract null null;
      }
    )
    (
      assertionBase
      // {
        "fixture/two" = rosterContract "fixture/one" null;
      }
    )
    (
      assertionBase
      // {
        "fixture/one" = rosterContract "fixture/collision" null;
        "fixture/normalized" = normalizedContract // {
          allowedOutcomeIds = [ "fixture/collision" ];
        };
      }
    )
    (
      assertionBase
      // {
        "fixture/one" = rosterContract "fixture/one" "duplicateResource";
        "fixture/two" = rosterContract "fixture/two" "duplicateResource";
      }
    )
    (
      assertionBase
      // {
        "fixture/one" = rosterContract "fixture/one" "normalizedResource";
      }
    )
    (
      assertionBase
      // {
        "fixture/one" = rosterContract "fixture/one" "serviceRestarts";
      }
    )
    (
      assertionBase
      // {
        "fixture/normalized" = normalizedContract // {
          resourceKey = "otherResource";
        };
      }
    )
    (
      assertionBase
      // {
        "fixture/normalized-two" = normalizedContract // {
          checkId = "fixture/normalized-two";
          resourceKey = "normalizedResourceTwo";
          requiredResourceKeys = [ "normalizedResourceTwo" ];
        };
      }
    )
  ];

  productionRegistry = hostConfig.dotfiles.observations;
  productionRows = hostConfig.dotfiles.commands.doctor.observations;
  productionKinds = lib.sort builtins.lessThan (
    lib.unique (map (row: row.value.kind) productionRows)
  );
  expectedKinds = [
    "command-version"
    "container-image"
    "deployed-path"
    "filesystem-threshold"
    "http-health"
    "journal-size"
    "managed-roots"
    "normalized-protocol"
    "numeric-command-threshold"
    "path-match"
    "path-metadata"
    "release-tree"
    "restart-counter"
    "roster"
    "swap-policy"
    "systemd-service"
    "systemd-timer"
  ];
  productionProjectionMatches = lib.all (
    row:
    let
      source = productionRegistry.${row.key};
      expected = lib.mapAttrs (name: value: if name == "command" then lib.getExe value else value) source;
    in
    row.value == expected
  ) productionRows;
in
{
  doctor-coverage =
    assert map (row: row.key) productionRows == builtins.attrNames productionRegistry;
    assert productionKinds == expectedKinds;
    assert productionProjectionMatches;
    assert assertionsHold assertionBase;
    assert lib.all (registry: !(assertionsHold registry)) invalidAssertionRegistries;
    assert lib.all (assertion: assertion.assertion) hostConfig.assertions;
    pkgs.runCommandLocal "check-doctor-coverage"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail

        test -x ${lib.getExe hostConfig.dotfiles.commands.doctor}
        test -x ${lib.getExe hostConfig.dotfiles.commands.doctor.probe}
        grep -Fq ${lib.escapeShellArg (lib.getExe hostConfig.dotfiles.commands.doctor.probe)} \
          ${lib.getExe hostConfig.dotfiles.commands.doctor}
        if grep -En 'DOTFILES_DOCTOR_FIXTURE|probeOverride|fixture-' \
          ${lib.getExe hostConfig.dotfiles.commands.doctor} \
          ${lib.getExe hostConfig.dotfiles.commands.doctor.probe}; then
          echo "production doctor contains a fixture probe hook" >&2
          exit 1
        fi

        for kind in ${lib.concatStringsSep " " expectedKinds}; do
          test "$(grep -Ec "^[[:space:]]*$kind\\) probe_[a-z_]+ ;;" ${../impl/probe.sh})" -eq 1
        done

        forbidden='agentTable|artifactTable|secretTable|serviceTable|maintenanceTable|managedRootTable|containerTable|healthTable|mcpTable|gatewayUrl|decode_response|probe_timeout_seconds|minimum_swap_bytes|root_warning_percent|root_failure_percent|windows_warning_percent|windows_failure_percent|maximum_journal_bytes|restart_warning_count|restart_failure_count'
        if grep -ERn "$forbidden" \
          ${../module.nix} ${../package.nix} ${../impl/doctor.sh} ${../impl/probe.sh}; then
          echo "legacy doctor specialization remains" >&2
          exit 1
        fi
        touch "$out"
      '';

}
