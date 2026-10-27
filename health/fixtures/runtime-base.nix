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
    for name in curl df docker journalctl stat swapon systemctl zramctl; do
      ln -s ../libexec/fake-runtime-tool "$out/bin/$name"
    done
  '';
  tools = {
    cmp = "${pkgs.diffutils}/bin/cmp";
    curl = "${fakeTools}/bin/curl";
    df = "${fakeTools}/bin/df";
    docker = "${fakeTools}/bin/docker";
    find = "${pkgs.findutils}/bin/find";
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
  agentSlice = "/user.slice/user-1000.slice/user@1000.service/agents.slice";
  mkProcFixture =
    name: processes:
    pkgs.runCommandLocal name { } ''
      mkdir -p "$out"
      process() {
        mkdir -p "$out/$1"
        ln -s "$2" "$out/$1/exe"
        printf '0::%s\n' "$3" >"$out/$1/cgroup"
      }
      ${lib.concatMapStringsSep "\n" (row: "process ${lib.escapeShellArgs row}") processes}
    '';
  procFixture = mkProcFixture "dotfiles-doctor-fixture-proc" [
    [
      "101"
      "/fixture/agents/omp/releases/a/bin/omp"
      "${agentSlice}/dotfiles-agent-omp.101.a.scope"
    ]
    [
      "102"
      "/fixture/bin/bash"
      "/init.scope"
    ]
    [
      "103"
      "/fixture/agents/omp/releases-old/bin/omp"
      "/init.scope"
    ]
    [
      "104"
      "/fixture/agents/claude/versions/2.0.0 (deleted)"
      "${agentSlice}/dotfiles-agent-claude.104.b.scope"
    ]
    [
      "105"
      "/fixture/store/aaaaaaaa-omp-1.0/lib/omp/omp"
      "${agentSlice}/dotfiles-agent-omp.105.c.scope"
    ]
    [
      "107"
      "/fixture/store/cccccccc-ompx-1.0/bin/other"
      "/init.scope"
    ]
  ];
  strayProcFixture = mkProcFixture "dotfiles-doctor-fixture-stray-proc" [
    [
      "101"
      "/fixture/agents/omp/releases/a/bin/omp"
      "${agentSlice}/dotfiles-agent-omp.101.a.scope"
    ]
    [
      "201"
      "/fixture/agents/omp/releases/b/bin/omp (deleted)"
      "/init.scope"
    ]
    [
      "202"
      "/fixture/agents/omp/releases/a/bin/omp"
      "/user.slice/user-1000.slice/user@1000.service/xagents.slice/stray.scope"
    ]
  ];
  emptyProcFixture = mkProcFixture "dotfiles-doctor-fixture-empty-proc" [ ];
  mkFixtureDoctor =
    values:
    mkDoctor {
      inherit pkgs lib tools;
      procRoot = procFixture;
      observations = rowsFor values;
    };
  mkFixtureDoctorWithTools =
    fixtureTools: values:
    mkDoctor {
      inherit pkgs lib;
      tools = fixtureTools;
      observations = rowsFor values;
    };
  zramPathSwapon = pkgs.writeShellApplication {
    name = "fixture-swapon-zram-path";
    text = ''
      printf '/zram0 partition 4294967296 100\n/dev/sda partition 4294967296 -2\n'
    '';
  };
  zramInvalidPathSwapon = pkgs.writeShellApplication {
    name = "fixture-swapon-invalid-zram-path";
    text = ''
      printf '/dev/zram0-not-a-device partition 4294967296 100\n/dev/sda partition 4294967296 -2\n'
    '';
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
  numericSetPassCommand = mkOutputCommand "fixture-numeric-set-pass" "c 20\nd 30";
  numericSetWarnCommand = mkOutputCommand "fixture-numeric-set-warn" "c 10";
  numericSetFailCommand = mkOutputCommand "fixture-numeric-set-fail" "c 9\nd 5";
  numericSetUsedCommand = mkOutputCommand "fixture-numeric-set-used" "c 90\nd 96";
  # 同じ名前の重複、ID に使えない名前、範囲外、雑音、過大、非ゼロ終了は、どれも observation 全体の失敗にする
  numericSetInvalidCommands = {
    empty = mkOutputCommand "fixture-numeric-set-empty" "";
    duplicate = mkOutputCommand "fixture-numeric-set-duplicate" "c 20\nc 30";
    uppercase = mkOutputCommand "fixture-numeric-set-uppercase" "C 20";
    range = mkOutputCommand "fixture-numeric-set-range" "c 101";
    noise = mkOutputCommand "fixture-numeric-set-noise" "c 20\njunk";
    oversize = pkgs.writeShellApplication {
      name = "fixture-numeric-set-oversize";
      text = "for index in {1..1000}; do printf 'd%s 20\\n' \"$index\"; done";
    };
    nonzero = pkgs.writeShellApplication {
      name = "fixture-numeric-set-nonzero";
      text = "printf 'c 20\\n'; exit 3";
    };
  };

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
  normalizedSlowCommand = pkgs.writeShellApplication {
    name = "fixture-normalized-slow";
    runtimeInputs = [ pkgs.coreutils ];
    text = "sleep 30";
  };
  killedProbe = pkgs.writeShellApplication {
    name = "fixture-killed-probe";
    text = "kill -KILL $$";
  };

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
    "fixture/08-systemd-service" = common "systemd-service" "systemd-service" // {
      manager = "system";
      unit = "service-ok.service";
      loadStates = [ "loaded" ];
      activeStates = [ "active" ];
      results = [ "success" ];
    };
    "fixture/08b-systemd-socket" = common "systemd-socket" "systemd-socket" // {
      manager = "system";
      unit = "socket-ok.socket";
      loadStates = [ "loaded" ];
      activeStates = [ "active" ];
      results = [ "success" ];
    };
    "fixture/09-systemd-timer" = common "systemd-timer" "systemd-timer" // {
      manager = "system";
      timer = "timer-ok.timer";
      service = "timer-ok.service";
      unitFileStates = [ "enabled" ];
      activeStates = [ "active" ];
      serviceResults = [ "success" ];
    };
    "fixture/09b-timer-exit" = common "timer-exit" "systemd-timer" // {
      manager = "system";
      timer = "timer-ok.timer";
      service = "timer-ok.service";
      unitFileStates = [ "enabled" ];
      activeStates = [ "active" ];
      serviceResults = [ "success" ];
    };
    "fixture/10-restart-service" = common "restart-service" "restart-counter" // {
      manager = "system";
      sourceKind = "systemd-service";
      target = "service-ok.service";
      warningAt = 5;
      failureAt = 20;
    };
    "fixture/11-restart-container" = common "restart-container" "restart-counter" // {
      manager = "system";
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
    "fixture/19-numeric-set" = common "numeric-set" "numeric-command-threshold-set" // {
      command = lib.getExe numericSetPassCommand;
      metric = "free-percent";
      warning = 15;
      failure = 10;
      resourceKey = "fixtureNumericSet";
    };
    "fixture/20-process-slice" = common "process-slice" "process-slice" // {
      executableRoots = [
        "/fixture/agents/omp/releases"
        "/fixture/agents/claude/versions"
        "/fixture/store/????????-omp-*"
      ];
      slice = "agents.slice";
      resourceKey = "fixtureProcessSlice";
    };
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
    "fixture/05-deployed-path" = passValues."fixture/05-deployed-path" // {
      destination = "/fixture/missing-deployment";
    };
    "fixture/06-path-metadata" = passValues."fixture/06-path-metadata" // {
      path = "/fixture/metadata-error";
    };
    "fixture/08-systemd-service" = passValues."fixture/08-systemd-service" // {
      unit = "service-fail.service";
    };
    "fixture/08b-systemd-socket" = passValues."fixture/08b-systemd-socket" // {
      unit = "socket-fail.socket";
    };
    "fixture/09-systemd-timer" = passValues."fixture/09-systemd-timer" // {
      timer = "timer-fail.timer";
    };
    "fixture/09b-timer-exit" = passValues."fixture/09b-timer-exit" // {
      service = "timer-exit-fail.service";
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
    "fixture/19-numeric-set" = passValues."fixture/19-numeric-set" // {
      command = lib.getExe numericSetFailCommand;
    };
    "fixture/20-process-slice" = passValues."fixture/20-process-slice" // {
      slice = "other.slice";
    };
  };
  zramPathDoctor =
    mkFixtureDoctorWithTools
      (
        tools
        // {
          swapon = lib.getExe zramPathSwapon;
        }
      )
      {
        "fixture/swap-zram-path" = passValues."fixture/14-swap" // {
          checkId = "fixture/swap-zram-path";
        };
      };
  zramInvalidPathDoctor =
    mkFixtureDoctorWithTools
      (
        tools
        // {
          swapon = lib.getExe zramInvalidPathSwapon;
        }
      )
      {
        "fixture/swap-invalid-zram-path" = passValues."fixture/14-swap" // {
          checkId = "fixture/swap-invalid-zram-path";
          failureMessage = "fixture swap-invalid-zram-path failed";
        };
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
    "fixture/05-numeric-set" = passValues."fixture/19-numeric-set" // {
      checkId = "fixture/warn-numeric-set";
      command = lib.getExe numericSetWarnCommand;
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
  strayProcessDoctor = mkDoctor {
    inherit pkgs lib tools;
    procRoot = strayProcFixture;
    observations = rowsFor {
      "fixture/stray-process" = passValues."fixture/20-process-slice" // {
        checkId = "fixture/stray-process";
        failureMessage = "fixture stray-process failed";
      };
    };
  };
  unreadableProcessDoctor = mkDoctor {
    inherit pkgs lib tools;
    procRoot = emptyProcFixture;
    observations = rowsFor {
      "fixture/unreadable-process" = passValues."fixture/20-process-slice" // {
        checkId = "fixture/unreadable-process";
        failureMessage = "fixture unreadable-process failed";
      };
    };
  };
  timeoutDoctor = mkFixtureDoctor {
    "fixture/normalized-timeout" = (normalizedValue normalizedTimeoutCommand) // {
      checkId = "fixture/timeout-fallback";
      timeoutSeconds = 1;
    };
  };
  termTimeoutDoctor = mkFixtureDoctor {
    "fixture/normalized-slow" = (normalizedValue normalizedSlowCommand) // {
      checkId = "fixture/term-timeout";
      timeoutSeconds = 1;
    };
  };
  killedProbeDoctor = mkDoctor {
    inherit pkgs lib tools;
    observations = rowsFor {
      "fixture/killed-probe" = common "killed-probe" "roster" // {
        members = [ "fixture" ];
        minimumCount = 1;
        failureOnly = false;
      };
    };
    probeOverride = killedProbe;
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
  numericSetUsedDoctor = mkFixtureDoctor {
    "fixture/numeric-set-used" = passValues."fixture/19-numeric-set" // {
      checkId = "fixture/numeric-set-used";
      command = lib.getExe numericSetUsedCommand;
      metric = "used-percent";
      warning = 85;
      failure = 95;
      resourceKey = "fixtureNumericSetUsed";
    };
  };
  numericSetInvalidDoctors = lib.mapAttrs (
    name: command:
    mkFixtureDoctor {
      "fixture/numeric-set-invalid-${name}" = passValues."fixture/19-numeric-set" // {
        checkId = "fixture/numeric-set-invalid-${name}";
        command = lib.getExe command;
      };
    }
  ) numericSetInvalidCommands;
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
  expectedStatuses =
    overrides:
    {
      timer = "pass";
      service = "pass";
      restart = "pass";
    }
    // overrides;
  managerCases = {
    healthy = {
      system = expectedStatuses { };
      user = expectedStatuses { };
    };
    manager-down = {
      system = expectedStatuses { };
      user = expectedStatuses {
        timer = "fail";
        service = "fail";
        restart = "fail";
      };
    };
    status-split-user = {
      system = expectedStatuses { };
      user = expectedStatuses { timer = "fail"; };
    };
    status-split-system = {
      system = expectedStatuses { timer = "fail"; };
      user = expectedStatuses { };
    };
    result-split-user = {
      system = expectedStatuses { };
      user = expectedStatuses {
        timer = "fail";
        service = "fail";
      };
    };
    only-user = {
      system = expectedStatuses {
        timer = "fail";
        service = "fail";
      };
      user = expectedStatuses { };
    };
    only-system = {
      system = expectedStatuses { };
      user = expectedStatuses {
        timer = "fail";
        service = "fail";
      };
    };
  };
  mkManagerDoctor =
    caseName: manager:
    mkFixtureDoctor {
      "fixture/${caseName}-${manager}-timer" = common "${caseName}-${manager}-timer" "systemd-timer" // {
        inherit manager;
        timer = "shared-${caseName}.timer";
        service = "shared-${caseName}.service";
        unitFileStates = [ "enabled" ];
        activeStates = [ "active" ];
        serviceResults = [ "success" ];
      };
      "fixture/${caseName}-${manager}-service" =
        common "${caseName}-${manager}-service" "systemd-service"
        // {
          inherit manager;
          unit = "shared-${caseName}.service";
          loadStates = [ "loaded" ];
          activeStates = [ "active" ];
          results = [ "success" ];
        };
      "fixture/${caseName}-${manager}-restart" =
        common "${caseName}-${manager}-restart" "restart-counter"
        // {
          inherit manager;
          sourceKind = "systemd-service";
          target = "shared-${caseName}.service";
          warningAt = 5;
          failureAt = 20;
        };
    };
  managerDoctors = lib.mapAttrs (
    caseName: managers:
    lib.mapAttrs (manager: expectation: {
      inherit expectation;
      doctor = mkManagerDoctor caseName manager;
    }) managers
  ) managerCases;
  timerStateDoctors =
    lib.mapAttrs
      (state: status: {
        inherit status;
        doctor = mkFixtureDoctor {
          "fixture/timer-state" = common "timer-state" "systemd-timer" // {
            manager = "user";
            timer = "timer-ok.timer";
            service = "timer-state-${state}.service";
            unitFileStates = [ "enabled" ];
            activeStates = [ "active" ];
            serviceResults = [ "success" ];
          };
        };
      })
      {
        starting = "warn";
        running = "warn";
        draining = "warn";
        completed = "pass";
        retained = "pass";
        failed-running = "fail";
        failed-cleared = "fail";
        failed-state = "fail";
        inconsistent = "fail";
      };
  servicePlacementDoctors =
    lib.mapAttrs
      (state: status: {
        inherit status;
        doctor = mkFixtureDoctor {
          "fixture/service-placement" = common "service-placement" "systemd-service" // {
            manager = "system";
            unit = "placement-${state}.service";
            slice = "fixture-workload.slice";
            loadStates = [ "loaded" ];
            activeStates = [
              "active"
              "inactive"
            ];
            results = [ "success" ];
          };
        };
      })
      {
        inside = "pass";
        nested = "pass";
        outside = "fail";
        prefix = "fail";
        empty = "fail";
        inactive = "pass";
        inactive-outside = "fail";
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
    killedProbeDoctor
    managerDoctors
    numericNoiseDoctor
    numericOversizeDoctor
    numericSetInvalidDoctors
    numericSetUsedDoctor
    zramInvalidPathDoctor
    zramPathDoctor
    passDoctor
    poisonDoctor
    restartThresholdFailureDoctor
    rosterFailureOnlyDoctor
    rosterOmitDoctor
    servicePlacementDoctors
    strayProcessDoctor
    termTimeoutDoctor
    timeoutDoctor
    timerStateDoctors
    unreadableProcessDoctor
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
