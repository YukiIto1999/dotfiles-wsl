{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
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
        markedSetCommand =
          (pkgs.writeShellApplication {
            name = "fixture-marked-set";
            text = "exit 0";
          }).overrideAttrs
            (old: {
              meta = (old.meta or { }) // {
                mainProgram = "fixture-marked-set";
              };
              passthru = (old.passthru or { }) // {
                dotfilesObservationCommandKind = "numeric-command-threshold-set";
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
        setContract = {
          kind = "numeric-command-threshold-set";
          checkId = "fixture/set";
          resourceKey = "setResource";
          timeoutSeconds = 10;
          failureMessage = "fixture set failed";
          command = markedSetCommand;
          metric = "free-percent";
          warning = 15;
          failure = 10;
        };
        evalRegistry =
          registry:
          lib.evalModules {
            specialArgs = { inherit pkgs; };
            modules = [
              ../../platform/cli/module.nix
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
                config.dotfiles.health.observations = registry;
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
                ++ [ evaluation.config.dotfiles.platform.cli.commands.doctor.drvPath ]
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
          "fixture/set" = setContract;
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
          # 集合の item は「<checkId>/<名前>」になるので、その下に別の check ID を置けない
          (
            assertionBase
            // {
              "fixture/one" = rosterContract "fixture/set/c" null;
            }
          )
          (
            assertionBase
            // {
              "fixture/normalized" = normalizedContract // {
                allowedOutcomeIds = [ "fixture/set/c" ];
                requiredOutcomeIds = [ "fixture/set/c" ];
              };
            }
          )
        ];

      in
      {
        doctor-coverage =
          assert assertionsHold assertionBase;
          assert lib.all (registry: !(assertionsHold registry)) invalidAssertionRegistries;
          assert lib.all (assertion: assertion.assertion) hostConfig.assertions;
          pkgs.runCommandLocal "check-doctor-coverage" { } "touch $out";

      }
    )
  ];
}
