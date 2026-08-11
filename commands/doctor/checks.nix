{
  pkgs,
  lib,
  hostConfig,
  helpers,
  ...
}:

let
  mkDoctor = import ./package.nix;
  mkRow = key: value: { inherit key value; };
  rowsFor =
    values: map (key: mkRow key values.${key}) (lib.sort builtins.lessThan (builtins.attrNames values));
  common = id: kind: {
    inherit kind;
    checkId = "fixture/${id}";
    resourceKey = null;
    timeoutSeconds = 10;
    failureMessage = "fixture ${id} failed";
  };

  fakeTools = pkgs.runCommandLocal "dotfiles-doctor-generic-fixture-tools" { } ''
    mkdir -p "$out/bin" "$out/libexec"
    cp ${./fixtures/fake-runtime-tool.sh} "$out/libexec/fake-runtime-tool"
    chmod +x "$out/libexec/fake-runtime-tool"
    patchShebangs "$out/libexec/fake-runtime-tool"
    for name in curl df docker du journalctl stat swapon systemctl zramctl; do
      ln -s ../libexec/fake-runtime-tool "$out/bin/$name"
    done
  '';
  tools = {
    cmp = "${pkgs.diffutils}/bin/cmp";
    curl = "${fakeTools}/bin/curl";
    df = "${fakeTools}/bin/df";
    docker = "${fakeTools}/bin/docker";
    du = "${fakeTools}/bin/du";
    env = "${pkgs.coreutils}/bin/env";
    head = "${pkgs.coreutils}/bin/head";
    journalctl = "${fakeTools}/bin/journalctl";
    jq = lib.getExe pkgs.jq;
    mktemp = "${pkgs.coreutils}/bin/mktemp";
    readlink = "${pkgs.coreutils}/bin/readlink";
    rm = "${pkgs.coreutils}/bin/rm";
    stat = "${fakeTools}/bin/stat";
    swapon = "${fakeTools}/bin/swapon";
    systemctl = "${fakeTools}/bin/systemctl";
    timeout = "${pkgs.coreutils}/bin/timeout";
    wc = "${pkgs.coreutils}/bin/wc";
    zramctl = "${fakeTools}/bin/zramctl";
  };
  mkFixtureDoctor =
    values:
    mkDoctor {
      inherit pkgs lib tools;
      observations = rowsFor values;
    };
  mkOutputCommand =
    name: output:
    pkgs.writeShellApplication {
      inherit name;
      text = "printf '%s\\n' ${lib.escapeShellArg output}";
    };

  versionCommand = pkgs.writeShellApplication {
    name = "fixture-version";
    text = ''
      [[ ''${1-} == --version ]]
      printf 'fixture 1.0\n'
    '';
  };
  numericPassCommand = mkOutputCommand "fixture-numeric-pass" "20";
  numericWarnCommand = mkOutputCommand "fixture-numeric-warn" "10";
  numericFailCommand = mkOutputCommand "fixture-numeric-fail" "9";
  numericOversizeCommand = pkgs.writeShellApplication {
    name = "fixture-numeric-oversize";
    runtimeInputs = [ pkgs.coreutils ];
    text = "head -c 65 /dev/zero | tr '\\0' 1";
  };
  numericNoiseCommand = mkOutputCommand "fixture-numeric-noise" "20\njunk";

  normalizedPassEnvelope = {
    schemaVersion = 1;
    outcomes = [
      {
        id = "fixture/protocol";
        status = "pass";
        message = "fixture protocol passed";
      }
    ];
    resources = [
      {
        key = "fixtureProtocol";
        value = {
          state = "ok";
        };
      }
    ];
  };
  normalizedFailEnvelope = normalizedPassEnvelope // {
    outcomes = [
      {
        id = "fixture/protocol";
        status = "fail";
        message = "fixture protocol failed";
      }
    ];
  };
  normalizedDuplicateEnvelope = normalizedPassEnvelope // {
    outcomes = [
      {
        id = "fixture/protocol";
        status = "pass";
        message = "first";
      }
      {
        id = "fixture/protocol";
        status = "fail";
        message = "second";
      }
    ];
  };
  normalizedEmptyEnvelope = normalizedPassEnvelope // {
    outcomes = [ ];
    resources = [
      {
        key = "fixtureProtocol";
        value = {
          state = "disabled";
        };
      }
    ];
  };
  normalizedPassCommand = mkOutputCommand "fixture-normalized-pass" (
    builtins.toJSON normalizedPassEnvelope
  );
  normalizedFailCommand = mkOutputCommand "fixture-normalized-fail" (
    builtins.toJSON normalizedFailEnvelope
  );
  normalizedDuplicateCommand = mkOutputCommand "fixture-normalized-duplicate" (
    builtins.toJSON normalizedDuplicateEnvelope
  );
  normalizedEmptyCommand = mkOutputCommand "fixture-normalized-empty" (
    builtins.toJSON normalizedEmptyEnvelope
  );
  normalizedPoisonCommand = pkgs.writeShellApplication {
    name = "fixture-normalized-poison";
    text = ''
      printf 'raw-secret-stderr\n' >&2
      if [[ -v POISON_ENV ]]; then
        printf 'raw-secret-environment\n'
        exit 9
      fi
      printf '%s\n' ${lib.escapeShellArg (builtins.toJSON normalizedPassEnvelope)}
    '';
  };
  normalizedNonzeroCommand = pkgs.writeShellApplication {
    name = "fixture-normalized-nonzero";
    text = ''
      printf 'raw-secret-stdout\n'
      printf 'raw-secret-stderr\n' >&2
      exit 9
    '';
  };
  normalizedOversizeCommand = pkgs.writeShellApplication {
    name = "fixture-normalized-oversize";
    runtimeInputs = [ pkgs.coreutils ];
    text = "head -c 65537 /dev/zero | tr '\\0' x";
  };
  normalizedTimeoutCommand = pkgs.writeShellApplication {
    name = "fixture-normalized-timeout";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      trap "" TERM
      (
        trap "" TERM
        while :; do sleep 1; done
      ) &
      printf '%s\n' "$!" > "$PWD/orphan.pid"
      wait
    '';
  };

  releaseFixture = pkgs.runCommandLocal "dotfiles-doctor-release-fixture" { } ''
    mkdir -p "$out/bin" "$out/releases/sha256-pass/bin" "$out/releases/sha256-pass/share"
    cp ${lib.getExe versionCommand} "$out/releases/sha256-pass/bin/tool"
    ln -s releases/sha256-pass "$out/current"
    ln -s ../current/bin/tool "$out/bin/tool"
  '';
  releaseEscapeFixture = pkgs.runCommandLocal "dotfiles-doctor-release-escape-fixture" { } ''
    mkdir -p "$out/bin" "$out/releases/sha256-escape/bin" "$out/releases/sha256-escape/share"
    cp ${lib.getExe versionCommand} "$out/outside-tool"
    ln -s ../../../outside-tool "$out/releases/sha256-escape/bin/tool"
    ln -s releases/sha256-escape "$out/current"
    ln -s ../current/bin/tool "$out/bin/tool"
  '';
  releaseDirectoryFixture = pkgs.runCommandLocal "dotfiles-doctor-release-directory-fixture" { } ''
    mkdir -p "$out/bin" "$out/releases/sha256-directory/bin/tool"
    ln -s releases/sha256-directory "$out/current"
    ln -s ../current/bin/tool "$out/bin/tool"
  '';
  releaseNonExecutableFixture =
    pkgs.runCommandLocal "dotfiles-doctor-release-non-executable-fixture" { }
      ''
        mkdir -p "$out/bin" "$out/releases/sha256-non-executable/bin"
        cp ${lib.getExe versionCommand} "$out/releases/sha256-non-executable/bin/tool"
        chmod -x "$out/releases/sha256-non-executable/bin/tool"
        ln -s releases/sha256-non-executable "$out/current"
        ln -s ../current/bin/tool "$out/bin/tool"
      '';
  deployedSource = pkgs.writeText "dotfiles-doctor-deployed-source" "fixture";
  deployedDestination = pkgs.writeText "dotfiles-doctor-deployed-destination" "fixture";
  pathFixture = pkgs.writeText "dotfiles-doctor-path-fixture" "fixture";

  normalizedValue =
    command:
    common "normalized-fallback" "normalized-protocol"
    // {
      command = lib.getExe command;
      allowedOutcomeIds = [
        "fixture/optional"
        "fixture/protocol"
      ];
      requiredOutcomeIds = [ "fixture/protocol" ];
      requiredResourceKeys = [ "fixtureProtocol" ];
      envelopeVersion = 1;
      resourceKey = "fixtureProtocol";
    };

  passValues = {
    "fixture/01-roster" = common "roster" "roster" // {
      members = [ "fixture" ];
      minimumCount = 1;
      failureOnly = false;
    };
    "fixture/02-path-match" = common "path-match" "path-match" // {
      currentPath = toString pathFixture;
      requiredPath = toString pathFixture;
      resolution = "canonical";
    };
    "fixture/03-command-version" = common "command-version" "command-version" // {
      path = lib.getExe versionCommand;
      expectedSource = lib.getExe versionCommand;
      versionArgs = [ "--version" ];
    };
    "fixture/04-release-tree" = common "release-tree" "release-tree" // {
      visiblePath = "${releaseFixture}/bin/tool";
      visibleTarget = "../current/bin/tool";
      currentLink = "${releaseFixture}/current";
      releasesRoot = "${releaseFixture}/releases";
      entrypoint = "bin/tool";
      requiredPaths = {
        "bin/tool" = {
          kind = "file";
          executable = true;
        };
        share = {
          kind = "directory";
          executable = false;
        };
      };
      versionArgs = [ "--version" ];
    };
    "fixture/05-deployed-path" = common "deployed-path" "deployed-path" // {
      source = toString deployedSource;
      destination = toString deployedDestination;
      acceptedDestinationKinds = [ "regular-file" ];
    };
    "fixture/06-path-metadata" = common "path-metadata" "path-metadata" // {
      path = "/fixture/metadata-ok";
      owner = "root";
      group = "root";
      mode = "0400";
    };
    "fixture/07-managed-roots" = common "managed-roots" "managed-roots" // {
      paths = [ "/fixture/root-ok" ];
      missingAsZero = false;
      oneFileSystem = true;
      cachePolicy = "allocated-bytes";
      resourceKey = "managedRoots";
    };
    "fixture/08-systemd-service" = common "systemd-service" "systemd-service" // {
      unit = "service-ok.service";
      loadStates = [ "loaded" ];
      activeStates = [ "active" ];
      results = [ "success" ];
    };
    "fixture/09-systemd-timer" = common "systemd-timer" "systemd-timer" // {
      timer = "timer-ok.timer";
      service = "timer-ok.service";
      unitFileStates = [ "enabled" ];
      activeStates = [ "active" ];
      serviceResults = [ "success" ];
    };
    "fixture/10-restart-service" = common "restart-service" "restart-counter" // {
      sourceKind = "systemd-service";
      target = "service-ok.service";
      warningAt = 5;
      failureAt = 20;
    };
    "fixture/11-restart-container" = common "restart-container" "restart-counter" // {
      sourceKind = "container";
      target = "container-ok";
      warningAt = 5;
      failureAt = 20;
    };
    "fixture/12-filesystem" = common "filesystem" "filesystem-threshold" // {
      path = "/fixture/fs-pass";
      metric = "used-percent";
      warning = 85;
      failure = 95;
      resourceKey = "fixtureFilesystem";
    };
    "fixture/13-numeric" = common "numeric" "numeric-command-threshold" // {
      command = lib.getExe numericPassCommand;
      metric = "free-percent";
      warning = 15;
      failure = 10;
      resourceKey = "fixtureNumeric";
    };
    "fixture/14-swap" = common "swap" "swap-policy" // {
      minimumTotalBytes = 8589934592;
      requiredZramAlgorithm = "lzo-rle";
      requireZram = true;
      zramAboveDisk = true;
      resourceKey = "fixtureSwap";
    };
    "fixture/15-journal" = common "journal" "journal-size" // {
      maximumBytes = 2048;
      resourceKey = "fixtureJournal";
    };
    "fixture/16-container-image" = common "container-image" "container-image" // {
      container = "container-ok";
      image = "image-ok";
    };
    "fixture/17-http-health" = common "http-health" "http-health" // {
      method = "GET";
      url = "http://127.0.0.1/health-pass";
    };
    "fixture/18-normalized" = normalizedValue normalizedPassCommand;
  };
  failureValues = passValues // {
    "fixture/01-roster" = passValues."fixture/01-roster" // {
      members = [ ];
      minimumCount = 1;
    };
    "fixture/02-path-match" = passValues."fixture/02-path-match" // {
      currentPath = "/fixture/missing-current";
    };
    "fixture/03-command-version" = passValues."fixture/03-command-version" // {
      path = "/fixture/missing-command";
    };
    "fixture/04-release-tree" = passValues."fixture/04-release-tree" // {
      visibleTarget = "../current/bin/wrong";
    };
    "fixture/05-deployed-path" = passValues."fixture/05-deployed-path" // {
      destination = "/fixture/missing-deployment";
    };
    "fixture/06-path-metadata" = passValues."fixture/06-path-metadata" // {
      path = "/fixture/metadata-error";
    };
    "fixture/07-managed-roots" = passValues."fixture/07-managed-roots" // {
      paths = [
        "/fixture/root-ok"
        "/fixture/root-bad"
      ];
    };
    "fixture/08-systemd-service" = passValues."fixture/08-systemd-service" // {
      unit = "service-fail.service";
    };
    "fixture/09-systemd-timer" = passValues."fixture/09-systemd-timer" // {
      timer = "timer-fail.timer";
    };
    "fixture/10-restart-service" = passValues."fixture/10-restart-service" // {
      target = "service-error.service";
    };
    "fixture/11-restart-container" = passValues."fixture/11-restart-container" // {
      target = "container-error";
    };
    "fixture/12-filesystem" = passValues."fixture/12-filesystem" // {
      path = "/fixture/fs-fail";
    };
    "fixture/13-numeric" = passValues."fixture/13-numeric" // {
      command = lib.getExe numericFailCommand;
    };
    "fixture/14-swap" = passValues."fixture/14-swap" // {
      minimumTotalBytes = 8589934593;
    };
    "fixture/15-journal" = passValues."fixture/15-journal" // {
      maximumBytes = 100;
    };
    "fixture/16-container-image" = passValues."fixture/16-container-image" // {
      container = "container-mismatch";
    };
    "fixture/17-http-health" = passValues."fixture/17-http-health" // {
      url = "http://127.0.0.1/health-fail";
    };
    "fixture/18-normalized" = normalizedValue normalizedFailCommand;
  };
  warningValues = {
    "fixture/01-filesystem" = passValues."fixture/12-filesystem" // {
      checkId = "fixture/warn-filesystem";
      path = "/fixture/fs-warn";
    };
    "fixture/02-numeric" = passValues."fixture/13-numeric" // {
      checkId = "fixture/warn-numeric";
      command = lib.getExe numericWarnCommand;
    };
    "fixture/03-restart-service" = passValues."fixture/10-restart-service" // {
      checkId = "fixture/warn-service";
      target = "service-warn.service";
    };
    "fixture/04-restart-container" = passValues."fixture/11-restart-container" // {
      checkId = "fixture/warn-container";
      target = "container-warn";
    };
  };

  passDoctor = mkFixtureDoctor passValues;
  failureDoctor = mkFixtureDoctor failureValues;
  warningDoctor = mkFixtureDoctor warningValues;
  restartThresholdFailureDoctor = mkFixtureDoctor {
    "fixture/restart-threshold-failure" = passValues."fixture/10-restart-service" // {
      checkId = "fixture/restart-threshold-failure";
      target = "service-fail.service";
    };
  };
  duplicateDoctor = mkFixtureDoctor {
    "fixture/normalized-duplicate" = (normalizedValue normalizedDuplicateCommand) // {
      checkId = "fixture/duplicate-fallback";
    };
  };
  emptyNormalizedDoctor = mkFixtureDoctor {
    "fixture/normalized-empty" = (normalizedValue normalizedEmptyCommand) // {
      checkId = "fixture/empty-fallback";
      requiredOutcomeIds = [ ];
    };
  };
  poisonDoctor = mkFixtureDoctor {
    "fixture/normalized-poison" = (normalizedValue normalizedPoisonCommand) // {
      checkId = "fixture/poison-fallback";
    };
  };
  timeoutDoctor = mkFixtureDoctor {
    "fixture/normalized-timeout" = (normalizedValue normalizedTimeoutCommand) // {
      checkId = "fixture/timeout-fallback";
      timeoutSeconds = 1;
    };
  };
  numericOversizeDoctor = mkFixtureDoctor {
    "fixture/numeric-oversize" = passValues."fixture/13-numeric" // {
      checkId = "fixture/numeric-oversize";
      command = lib.getExe numericOversizeCommand;
    };
  };
  numericNoiseDoctor = mkFixtureDoctor {
    "fixture/numeric-noise" = passValues."fixture/13-numeric" // {
      checkId = "fixture/numeric-noise";
      command = lib.getExe numericNoiseCommand;
    };
  };
  filesystemFreeDoctor = mkFixtureDoctor {
    "fixture/filesystem-free" = passValues."fixture/12-filesystem" // {
      checkId = "fixture/filesystem-free";
      metric = "free-percent";
      warning = 15;
      failure = 10;
      resourceKey = "fixtureFilesystemFree";
    };
  };
  rosterOmitDoctor = mkFixtureDoctor {
    "fixture/roster-omit" = passValues."fixture/01-roster" // {
      checkId = "fixture/roster-omit";
      failureOnly = true;
    };
  };
  rosterFailureOnlyDoctor = mkFixtureDoctor {
    "fixture/roster-failure-only" = passValues."fixture/01-roster" // {
      checkId = "fixture/roster-failure-only";
      members = [ ];
      minimumCount = 1;
      failureOnly = true;
    };
  };
  releaseEscapeDoctor = mkFixtureDoctor {
    "fixture/release-escape" = passValues."fixture/04-release-tree" // {
      checkId = "fixture/release-escape";
      visiblePath = "${releaseEscapeFixture}/bin/tool";
      currentLink = "${releaseEscapeFixture}/current";
      releasesRoot = "${releaseEscapeFixture}/releases";
      requiredPaths = {
        share = {
          kind = "directory";
          executable = false;
        };
      };
    };
  };
  releaseDirectoryDoctor = mkFixtureDoctor {
    "fixture/release-directory" = passValues."fixture/04-release-tree" // {
      checkId = "fixture/release-directory";
      visiblePath = "${releaseDirectoryFixture}/bin/tool";
      currentLink = "${releaseDirectoryFixture}/current";
      releasesRoot = "${releaseDirectoryFixture}/releases";
      requiredPaths = { };
    };
  };
  releaseNonExecutableDoctor = mkFixtureDoctor {
    "fixture/release-non-executable" = passValues."fixture/04-release-tree" // {
      checkId = "fixture/release-non-executable";
      visiblePath = "${releaseNonExecutableFixture}/bin/tool";
      currentLink = "${releaseNonExecutableFixture}/current";
      releasesRoot = "${releaseNonExecutableFixture}/releases";
      requiredPaths = { };
    };
  };
  releaseMissingLinkObservations = {
    current = passValues."fixture/04-release-tree" // {
      checkId = "fixture/release-missing-current";
      currentLink = "${releaseFixture}/missing-current";
    };
    visible = passValues."fixture/04-release-tree" // {
      checkId = "fixture/release-missing-visible";
      visiblePath = "${releaseFixture}/bin/missing-visible";
    };
  };
  releaseMissingLinkFixtures = lib.mapAttrs (name: observation: {
    inherit observation;
    doctor = mkFixtureDoctor {
      "fixture/release-missing-${name}" = observation;
    };
  }) releaseMissingLinkObservations;
  managedSpaceDoctor = mkFixtureDoctor {
    "fixture/managed-space" = passValues."fixture/07-managed-roots" // {
      checkId = "fixture/managed-space";
      paths = [ "/fixture/root with space" ];
      resourceKey = "managedSpace";
    };
  };

  invalidNormalizedCommands = {
    nonzero = normalizedNonzeroCommand;
    oversize = normalizedOversizeCommand;
    noise = mkOutputCommand "fixture-normalized-noise" (
      (builtins.toJSON normalizedPassEnvelope) + " noise"
    );
    multiple = mkOutputCommand "fixture-normalized-multiple" "{}\n{}";
    top-key = mkOutputCommand "fixture-normalized-top-key" (
      builtins.toJSON (normalizedPassEnvelope // { extra = true; })
    );
    version = mkOutputCommand "fixture-normalized-version" (
      builtins.toJSON (normalizedPassEnvelope // { schemaVersion = 2; })
    );
    outcome-key = mkOutputCommand "fixture-normalized-outcome-key" (
      builtins.toJSON (
        normalizedPassEnvelope
        // {
          outcomes = [ ((builtins.head normalizedPassEnvelope.outcomes) // { extra = true; }) ];
        }
      )
    );
    outcome-id = mkOutputCommand "fixture-normalized-outcome-id" (
      builtins.toJSON (
        normalizedPassEnvelope
        // {
          outcomes = [
            {
              id = "fixture/unknown";
              status = "pass";
              message = "unknown";
            }
          ];
        }
      )
    );
    outcome-status = mkOutputCommand "fixture-normalized-outcome-status" (
      builtins.toJSON (
        normalizedPassEnvelope
        // {
          outcomes = [
            {
              id = "fixture/protocol";
              status = "unknown";
              message = "unknown";
            }
          ];
        }
      )
    );
    outcome-message = mkOutputCommand "fixture-normalized-outcome-message" (
      builtins.toJSON (
        normalizedPassEnvelope
        // {
          outcomes = [
            {
              id = "fixture/protocol";
              status = "pass";
              message = "";
            }
          ];
        }
      )
    );
    required-outcome-missing = normalizedEmptyCommand;
    resource-missing = mkOutputCommand "fixture-normalized-resource-missing" (
      builtins.toJSON (normalizedPassEnvelope // { resources = [ ]; })
    );
    resource-extra = mkOutputCommand "fixture-normalized-resource-extra" (
      builtins.toJSON (
        normalizedPassEnvelope
        // {
          resources = normalizedPassEnvelope.resources ++ [
            {
              key = "extra";
              value = null;
            }
          ];
        }
      )
    );
    resource-duplicate = mkOutputCommand "fixture-normalized-resource-duplicate" (
      builtins.toJSON (
        normalizedPassEnvelope
        // {
          resources = normalizedPassEnvelope.resources ++ normalizedPassEnvelope.resources;
        }
      )
    );
    resource-key = mkOutputCommand "fixture-normalized-resource-key" (
      builtins.toJSON (
        normalizedPassEnvelope
        // {
          resources = [ ((builtins.head normalizedPassEnvelope.resources) // { extra = true; }) ];
        }
      )
    );
  };
  invalidNormalizedDoctors = lib.mapAttrs (
    name: command:
    mkFixtureDoctor {
      "fixture/invalid-${name}" = (normalizedValue command) // {
        checkId = "fixture/invalid-${name}";
      };
    }
  ) invalidNormalizedCommands;
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
        ../module.nix
        ./module.nix
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
          test "$(grep -Ec "^[[:space:]]*$kind\\) probe_[a-z_]+ ;;" ${./impl/probe.sh})" -eq 1
        done

        forbidden='agentTable|artifactTable|secretTable|serviceTable|maintenanceTable|managedRootTable|containerTable|healthTable|mcpTable|gatewayUrl|decode_response|probe_timeout_seconds|minimum_swap_bytes|root_warning_percent|root_failure_percent|windows_warning_percent|windows_failure_percent|maximum_journal_bytes|restart_warning_count|restart_failure_count'
        if grep -ERn "$forbidden" \
          ${./module.nix} ${./package.nix} ${./impl/doctor.sh} ${./impl/probe.sh}; then
          echo "legacy doctor specialization remains" >&2
          exit 1
        fi
        touch "$out"
      '';

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
          (.checks | length) == 18
          and all(.checks[]; .status == "fail")
          and (.failures | length) == 18
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
