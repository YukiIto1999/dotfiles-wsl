{
  pkgs,
  lib,
  support,
}:

let
  inherit (support)
    mkDoctor
    mkOutputCommand
    normalizedPassCommand
    normalizedPassEnvelope
    normalizedValue
    passValues
    rowsFor
    tools
    ;
  validFragment = {
    checks = [ ];
    warnings = [ ];
    failures = [ ];
    resources = [ ];
    restart = null;
  };
  passFragment =
    id:
    validFragment
    // {
      checks = [
        {
          inherit id;
          status = "pass";
        }
      ];
    };
  semanticFragmentCases = {
    direct-missing-required-check.fragment = _: validFragment;
    duplicate-check-id.fragment =
      id:
      validFragment
      // {
        checks = [
          {
            inherit id;
            status = "pass";
          }
          {
            inherit id;
            status = "pass";
          }
        ];
      };
    duplicate-warning-id.fragment =
      id:
      validFragment
      // {
        checks = [
          {
            inherit id;
            status = "warn";
          }
        ];
        warnings = [
          {
            inherit id;
            message = "first warning";
          }
          {
            inherit id;
            message = "second warning";
          }
        ];
      };
    duplicate-failure-id.fragment =
      id:
      validFragment
      // {
        checks = [
          {
            inherit id;
            status = "fail";
          }
        ];
        failures = [
          {
            inherit id;
            message = "first failure";
          }
          {
            inherit id;
            message = "second failure";
          }
        ];
      };
    warn-without-warning.fragment =
      id:
      validFragment
      // {
        checks = [
          {
            inherit id;
            status = "warn";
          }
        ];
      };
    warning-without-warn.fragment =
      id:
      validFragment
      // {
        checks = [
          {
            inherit id;
            status = "pass";
          }
        ];
        warnings = [
          {
            inherit id;
            message = "unexpected warning";
          }
        ];
      };
    fail-without-failure.fragment =
      id:
      validFragment
      // {
        checks = [
          {
            inherit id;
            status = "fail";
          }
        ];
      };
    failure-without-fail.fragment =
      id:
      validFragment
      // {
        checks = [
          {
            inherit id;
            status = "pass";
          }
        ];
        failures = [
          {
            inherit id;
            message = "unexpected failure";
          }
        ];
      };
    duplicate-resource-key = {
      observation = {
        resourceKey = "declaredResource";
      };
      fragment =
        id:
        validFragment
        // {
          checks = [
            {
              inherit id;
              status = "pass";
            }
          ];
          resources = [
            {
              key = "declaredResource";
              value = 1;
            }
            {
              key = "declaredResource";
              value = 2;
            }
          ];
        };
    };
    undeclared-check-id.fragment =
      _:
      validFragment
      // {
        checks = [
          {
            id = "fixture/undeclared";
            status = "pass";
          }
        ];
      };
    undeclared-resource-key.fragment =
      id:
      validFragment
      // {
        checks = [
          {
            inherit id;
            status = "pass";
          }
        ];
        resources = [
          {
            key = "undeclaredResource";
            value = null;
          }
        ];
      };
    normalized-missing-required-check = {
      normalized = true;
      fragment =
        _:
        validFragment
        // {
          inherit (normalizedPassEnvelope) resources;
        };
    };
    normalized-missing-required-resource = {
      normalized = true;
      fragment =
        _:
        validFragment
        // {
          checks = [
            {
              id = "fixture/protocol";
              status = "pass";
            }
          ];
        };
    };
    normalized-undeclared-check = {
      normalized = true;
      fragment =
        _:
        validFragment
        // {
          checks = [
            {
              id = "fixture/undeclared";
              status = "pass";
            }
            {
              id = "fixture/protocol";
              status = "pass";
            }
          ];
          inherit (normalizedPassEnvelope) resources;
        };
    };
    nonrestart-restart-injection.fragment =
      id:
      passFragment id
      // {
        restart = {
          kind = "service";
          target = "service-ok.service";
          count = 0;
        };
      };
    restart-target-mismatch = {
      observation = {
        kind = "restart-counter";
        sourceKind = "systemd-service";
        target = "service-ok.service";
      };
      fragment =
        id:
        passFragment id
        // {
          restart = {
            kind = "service";
            target = "service-wrong.service";
            count = 0;
          };
        };
    };
    restart-service-kind-mismatch = {
      observation = {
        kind = "restart-counter";
        sourceKind = "systemd-service";
        target = "service-ok.service";
      };
      fragment =
        id:
        passFragment id
        // {
          restart = {
            kind = "container";
            target = "service-ok.service";
            count = 0;
          };
        };
    };
    restart-container-kind-mismatch = {
      observation = {
        kind = "restart-counter";
        sourceKind = "container";
        target = "container-ok";
      };
      fragment =
        id:
        passFragment id
        // {
          restart = {
            kind = "service";
            target = "container-ok";
            count = 0;
          };
        };
    };
    restart-pass-without-payload = {
      observation = {
        kind = "restart-counter";
        sourceKind = "systemd-service";
        target = "service-ok.service";
      };
      fragment = passFragment;
    };
    restart-warn-without-payload = {
      observation = {
        kind = "restart-counter";
        sourceKind = "systemd-service";
        target = "service-ok.service";
      };
      fragment =
        id:
        validFragment
        // {
          checks = [
            {
              inherit id;
              status = "warn";
            }
          ];
          warnings = [
            {
              inherit id;
              message = "restart warning without payload";
            }
          ];
        };
    };
  };
  semanticFragmentFixtures = lib.mapAttrs (
    name: fixture:
    let
      baseObservation =
        if fixture.normalized or false then
          normalizedValue normalizedPassCommand
        else
          passValues."fixture/01-roster";
      observation =
        baseObservation
        // (fixture.observation or { })
        // {
          checkId = "fixture/semantic-${name}";
          failureMessage = "fixture semantic ${name} failed";
        };
      fragment = fixture.fragment observation.checkId;
    in
    {
      inherit observation;
      doctor = mkDoctor {
        inherit pkgs lib tools;
        observations = rowsFor {
          "fixture/semantic-${name}" = observation;
        };
        probeOverride = mkOutputCommand "fixture-semantic-${name}" (builtins.toJSON fragment);
      };
    }
  ) semanticFragmentCases;
  restartFailureWithoutPayloadObservation = passValues."fixture/10-restart-service" // {
    checkId = "fixture/restart-failure-without-payload";
    failureMessage = "fixture restart-failure-without-payload fallback";
  };
  restartFailureWithoutPayloadDoctor = mkDoctor {
    inherit pkgs lib tools;
    observations = rowsFor {
      "fixture/restart-failure-without-payload" = restartFailureWithoutPayloadObservation;
    };
    probeOverride = mkOutputCommand "fixture-restart-failure-without-payload" (
      builtins.toJSON (
        validFragment
        // {
          checks = [
            {
              id = restartFailureWithoutPayloadObservation.checkId;
              status = "fail";
            }
          ];
          failures = [
            {
              id = restartFailureWithoutPayloadObservation.checkId;
              message = "restart failure without payload";
            }
          ];
        }
      )
    );
  };
  malformedArrayValues = {
    inherit null;
    object = { };
    scalar = 1;
  };
  malformedFragments = builtins.listToAttrs (
    lib.concatMap
      (
        field:
        lib.mapAttrsToList (shape: value: {
          name = "${field}-${shape}";
          value = validFragment // {
            ${field} = value;
          };
        }) malformedArrayValues
      )
      [
        "checks"
        "warnings"
        "failures"
        "resources"
      ]
  );
  malformedFragmentDoctors = lib.mapAttrs (
    name: fragment:
    mkDoctor {
      inherit pkgs lib tools;
      observations = rowsFor {
        "fixture/malformed-${name}" = passValues."fixture/01-roster" // {
          checkId = "fixture/malformed-${name}";
          failureMessage = "fixture malformed ${name} failed";
        };
      };
      probeOverride = mkOutputCommand "fixture-malformed-${name}" (builtins.toJSON fragment);
    }
  ) malformedFragments;

in
{
  inherit
    malformedFragmentDoctors
    restartFailureWithoutPayloadDoctor
    semanticFragmentFixtures
    ;
}
