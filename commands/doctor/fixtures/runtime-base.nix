{ pkgs, lib }:

let
  mkDoctor = import ../package.nix;
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
    cp ${./fake-runtime-tool.sh} "$out/libexec/fake-runtime-tool"
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

in
{
  inherit
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

  support = {
    inherit
      mkDoctor
      mkRow
      mkOutputCommand
      normalizedPassCommand
      normalizedPassEnvelope
      normalizedValue
      passValues
      rowsFor
      tools
      ;
  };
}
