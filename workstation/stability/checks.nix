{ pkgs, lib, ... }:

let
  mkReader = import ./impl/windows-snapshot-package.nix;
  mkCommit = import ./impl/windows-commit-package.nix;
  mkWorkload = import ./impl/workload-package.nix;
  mkCollector = import ./impl/windows-collector-package.nix;
  mkWslMemory = import ./impl/wsl-memory-package.nix;

  now = 1700000100;
  maximumAge = 60;
  futureSkew = 5;
  windowsPhysicalReserve = 8589934592;
  wslVmCommitOverhead = 2147483648;
  fixedDate = time: pkgs.writeShellScript "date-${toString time}" "printf '%s\\n' ${toString time}";
  failingCommand = pkgs.writeShellScript "failing-command" "exit 1";
  jsonOf = value: if builtins.isString value then value else builtins.toJSON value;
  mkCommitProbe = reader: mkCommit { inherit pkgs lib reader; };

  wslConfigRead = {
    state = "read";
    memoryBytes = 51539607552;
    processors = 12;
  };
  record = sampledAt: {
    schemaVersion = 1;
    inherit sampledAt;
    sequence = 7;
    intervalSeconds = 10;
    physicalTotalBytes = 34359738368;
    physicalAvailableBytes = 12884901888;
    commitUsedBytes = 21474836480;
    commitLimitBytes = 42949672960;
    wslConfig = wslConfigRead;
  };
  freshRecord = record (now - 3);
  commitRecord =
    used: limit:
    freshRecord
    // {
      commitUsedBytes = used;
      commitLimitBytes = limit;
    };
  # collector が VM の commit を報告した record。null は vmmem の process が無いか読めなかった場合
  vmCommitRecord = vmCommit: freshRecord // { wslVmCommitBytes = vmCommit; };

  mkReaderProbe =
    {
      snapshotPath,
      time ? now,
      dateCommand ? fixedDate time,
      headCommand ? "${pkgs.coreutils}/bin/head",
    }:
    mkReader {
      inherit
        pkgs
        lib
        dateCommand
        headCommand
        ;
      snapshotPath = toString snapshotPath;
      maximumAgeSeconds = maximumAge;
      futureSkewSeconds = futureSkew;
    };
  snapshotFile = name: content: pkgs.writeText "snapshot-${name}" (jsonOf content);
  readerFor = name: content: mkReaderProbe { snapshotPath = snapshotFile name content; };
  missingReader = mkReaderProbe { snapshotPath = "/nonexistent/windows-memory.json"; };

  nullNumbers = ".physicalTotalBytes == null and .physicalAvailableBytes == null and .commitUsedBytes == null and .commitLimitBytes == null and .wslConfig == null and has(\"wslVmCommitBytes\") and .wslVmCommitBytes == null";
  invalidRecords = {
    truncated = builtins.substring 0 60 (builtins.toJSON freshRecord);
    concatenated = builtins.toJSON freshRecord + builtins.toJSON freshRecord;
    appended-garbage = builtins.toJSON freshRecord + "x";
    empty = "";
    not-an-object = "[1]";
    null-value = "null";
    wrong-schema = freshRecord // {
      schemaVersion = 2;
    };
    negative = freshRecord // {
      commitUsedBytes = -1;
    };
    fractional = freshRecord // {
      sampledAt = 1.5;
    };
    string-number =
      builtins.replaceStrings
        [ ''"physicalTotalBytes":34359738368'' ]
        [ ''"physicalTotalBytes":"34359738368"'' ]
        (builtins.toJSON freshRecord);
    extra-key = freshRecord // {
      extra = 1;
    };
    missing-key = removeAttrs freshRecord [ "sequence" ];
    missing-wsl-config = removeAttrs freshRecord [ "wslConfig" ];
    wsl-config-not-an-object = freshRecord // {
      wslConfig = "read";
    };
    wsl-config-unknown-state = freshRecord // {
      wslConfig = wslConfigRead // {
        state = "stale";
      };
    };
    wsl-config-extra-key = freshRecord // {
      wslConfig = wslConfigRead // {
        extra = 1;
      };
    };
    wsl-config-missing-key = freshRecord // {
      wslConfig = removeAttrs wslConfigRead [ "processors" ];
    };
    wsl-config-zero-memory = freshRecord // {
      wslConfig = wslConfigRead // {
        memoryBytes = 0;
      };
    };
    wsl-config-negative-processors = freshRecord // {
      wslConfig = wslConfigRead // {
        processors = -1;
      };
    };
    wsl-config-string-memory = freshRecord // {
      wslConfig = wslConfigRead // {
        memoryBytes = "48GB";
      };
    };
    wsl-config-value-without-read = freshRecord // {
      wslConfig = {
        state = "missing";
        memoryBytes = 51539607552;
        processors = null;
      };
    };
    vm-commit-negative = freshRecord // {
      wslVmCommitBytes = -1;
    };
    vm-commit-fractional = freshRecord // {
      wslVmCommitBytes = 1.5;
    };
    vm-commit-string = freshRecord // {
      wslVmCommitBytes = "51200000000";
    };
    vm-commit-boolean = freshRecord // {
      wslVmCommitBytes = true;
    };
    vm-commit-unsafe-integer = freshRecord // {
      wslVmCommitBytes = 9007199254740992;
    };
    available-above-total = freshRecord // {
      physicalAvailableBytes = 34359738369;
    };
    zero-total = freshRecord // {
      physicalTotalBytes = 0;
      physicalAvailableBytes = 0;
    };
    zero-commit-limit = freshRecord // {
      commitLimitBytes = 0;
    };
    zero-sampled-at = freshRecord // {
      sampledAt = 0;
    };
    unsafe-integer = freshRecord // {
      commitUsedBytes = 9007199254740992;
    };
    oversized = builtins.toJSON freshRecord + lib.concatStrings (lib.replicate 5000 " ");
  };
  snapshotWithTemporary = pkgs.runCommandLocal "snapshot-with-temporary" { } ''
    mkdir -p "$out"
    cp ${snapshotFile "temporary-companion" freshRecord} "$out/windows-memory.json"
    printf '{"schemaVersion":1,"sampledAt' >"$out/windows-memory.json.0123456789abcdef.tmp"
  '';
  readerCases = {
    fresh = {
      reader = readerFor "fresh" freshRecord;
      filter = ''.state == "fresh" and .ageSeconds == 3 and .observedAt == ${toString (now - 3)} and .maximumAgeSeconds == ${toString maximumAge} and .physicalTotalBytes == 34359738368 and .physicalAvailableBytes == 12884901888 and .commitUsedBytes == 21474836480 and .commitLimitBytes == 42949672960 and .wslConfig == {"state":"read","memoryBytes":51539607552,"processors":12}'';
    };
    old-collector-record-has-no-vm-commit = {
      reader = readerFor "old-collector" freshRecord;
      filter = ''.state == "fresh" and has("wslVmCommitBytes") and .wslVmCommitBytes == null'';
    };
    vm-commit-passed-through = {
      reader = readerFor "vm-commit" (vmCommitRecord 52000000000);
      filter = ''.state == "fresh" and .wslVmCommitBytes == 52000000000 and .commitLimitBytes == 42949672960 and .wslConfig.state == "read"'';
    };
    vm-commit-null = {
      reader = readerFor "vm-commit-null" (vmCommitRecord null);
      filter = ''.state == "fresh" and has("wslVmCommitBytes") and .wslVmCommitBytes == null'';
    };
    vm-commit-zero = {
      reader = readerFor "vm-commit-zero" (vmCommitRecord 0);
      filter = ''.state == "fresh" and .wslVmCommitBytes == 0'';
    };
    vm-commit-of-a-stale-record-is-not-reported = {
      reader = readerFor "vm-commit-stale" (
        record (now - maximumAge - 1) // { wslVmCommitBytes = 52000000000; }
      );
      filter = ''.state == "stale" and ${nullNumbers}'';
    };
    oldest-accepted = {
      reader = readerFor "oldest" (record (now - maximumAge));
      filter = ''.state == "fresh" and .ageSeconds == ${toString maximumAge}'';
    };
    stale = {
      reader = readerFor "stale" (record (now - maximumAge - 1));
      filter = ''.state == "stale" and .ageSeconds == ${toString (maximumAge + 1)} and .observedAt == ${
        toString (now - maximumAge - 1)
      } and ${nullNumbers}'';
    };
    newest-within-skew = {
      reader = readerFor "skew-edge" (record (now + futureSkew));
      filter = ''.state == "fresh" and .ageSeconds == 0'';
    };
    future = {
      reader = readerFor "future" (record (now + futureSkew + 1));
      filter = ''.state == "future" and .ageSeconds == ${toString (-(futureSkew + 1))} and ${nullNumbers}'';
    };
    missing = {
      reader = missingReader;
      filter = ''.state == "unavailable" and .observedAt == null and .ageSeconds == null and ${nullNumbers}'';
    };
    directory = {
      reader = mkReaderProbe {
        snapshotPath = pkgs.runCommandLocal "snapshot-directory" { } ''mkdir "$out"'';
      };
      filter = ''.state == "unavailable"'';
    };
    clock-unreadable = {
      reader = mkReaderProbe {
        snapshotPath = snapshotFile "clock-unreadable" freshRecord;
        dateCommand = failingCommand;
      };
      filter = ''.state == "unavailable" and ${nullNumbers}'';
    };
    temporary-companion-ignored = {
      reader = mkReaderProbe { snapshotPath = "${snapshotWithTemporary}/windows-memory.json"; };
      filter = ''.state == "fresh" and .observedAt == ${toString (now - 3)}'';
    };
  }
  // lib.mapAttrs' (name: content: {
    name = "invalid-${name}";
    value = {
      reader = readerFor "invalid-${name}" content;
      filter = ''.state == "invalid" and .observedAt == null and .ageSeconds == null and ${nullNumbers}'';
    };
  }) invalidRecords;

  commitCases = {
    half = {
      reader = readerFor "commit-half" freshRecord;
      percent = "50";
    };
    floored = {
      reader = readerFor "commit-floor" (commitRecord 849 1000);
      percent = "84";
    };
    saturated = {
      reader = readerFor "commit-saturated" (commitRecord 50000 40000);
      percent = "100";
    };
    idle = {
      reader = readerFor "commit-idle" (commitRecord 0 1000);
      percent = "0";
    };
  };
  commitFailures = {
    stale = readerFor "commit-stale" (record (now - maximumAge - 1));
    future = readerFor "commit-future" (record (now + futureSkew + 1));
    invalid = readerFor "commit-invalid" invalidRecords.truncated;
    unavailable = missingReader;
  };

  mkTree =
    name: files:
    pkgs.runCommandLocal name { } ''
      mkdir -p "$out"
      ${lib.concatStrings (
        lib.mapAttrsToList (path: content: ''
          mkdir -p "$(dirname "$out"/${lib.escapeShellArg path})"
          printf '%s' ${lib.escapeShellArg content} >"$out"/${lib.escapeShellArg path}
        '') files
      )}
    '';
  level =
    path:
    {
      max ? "max",
      high ? "max",
      current ? 0,
      inactive ? 0,
      active ? 0,
      mapped ? 0,
      dirty ? 0,
      writeback ? 0,
      cpuMax ? "max 100000",
    }:
    {
      "${path}/cgroup.controllers" = "cpu memory\n";
      "${path}/memory.max" = "${toString max}\n";
      "${path}/memory.high" = "${toString high}\n";
      "${path}/memory.current" = "${toString current}\n";
      "${path}/memory.stat" =
        "anon 1\ninactive_file ${toString inactive}\nactive_file ${toString active}\n"
        + "file_mapped ${toString mapped}\nfile_dirty ${toString dirty}\nfile_writeback ${toString writeback}\n";
      "${path}/cpu.max" = "${cpuMax}\n";
    };
  rootController = {
    "cgroup.controllers" = "cpu io memory pids\n";
  };
  userSlice = {
    max = 900000000;
    high = 800000000;
    current = 500000000;
    inactive = 100000000;
  };
  userManager = {
    max = 400000000;
    current = 100000000;
    inactive = 20000000;
  };
  mkChain =
    {
      aggregate ? { },
      manager ? { },
      files ? (all: all),
    }:
    mkTree "cgroup-chain" (
      files (
        rootController
        // level "user.slice" (userSlice // aggregate)
        // level "user.slice/user-1000.slice" (userManager // manager)
        // level "user.slice/user-1000.slice/session-3.scope" { current = 50000000; }
      )
    );
  withoutFiles =
    names: files: removeAttrs files (map (name: "user.slice/user-1000.slice/${name}") names);
  sessionCgroup = "0::/user.slice/user-1000.slice/session-3.scope\n";

  meminfoOf =
    total: available:
    pkgs.writeText "meminfo-${toString total}-${toString available}" ''
      MemTotal:       ${toString total} kB
      MemFree:         100000 kB
      MemAvailable:   ${toString available} kB
      Buffers:              0 kB
    '';
  roomyMemory = meminfoOf 1000000 600000;
  affinityEight = pkgs.writeText "status-affinity" "Name:\tbash\nCpus_allowed_list:\t0-3,8-11\nMems_allowed_list:\t0\n";
  onlineTwelve = pkgs.writeText "cpu-online" "0-11\n";
  mkPressure =
    memory: io:
    mkTree "pressure-${memory}-${io}" {
      memory = "some avg10=1.00 avg60=1.00 avg300=1.00 total=1\nfull avg10=1.00 avg60=${memory} avg300=1.00 total=1\n";
      io = "some avg10=1.00 avg60=1.00 avg300=1.00 total=1\nfull avg10=1.00 avg60=${io} avg300=1.00 total=1\n";
    };
  calmPressure = mkPressure "9.99" "9.99";
  freshReader = readerFor "workload-fresh" freshRecord;

  mkWorkloadProbe =
    {
      reader ? freshReader,
      meminfo ? roomyMemory,
      cgroupRoot ? mkChain { },
      procCgroup ? pkgs.writeText "self-cgroup" sessionCgroup,
      procStatus ? affinityEight,
      cpuOnline ? onlineTwelve,
      pressureRoot ? calmPressure,
      declaredMemoryBytes ? null,
      declaredProcessors ? null,
      # the cgroup the observation is asked about: where a process is about to be placed, not where the caller is
      destination ? null,
      # the cgroups whose scopes' usage is asked for as well; they are given with a destination
      scopeParents ? [ ],
    }:
    let
      probe = mkWorkload {
        inherit
          pkgs
          lib
          reader
          declaredMemoryBytes
          declaredProcessors
          ;
        hostReservePercent = 20;
        aggregateCgroup = "/user.slice";
        pressureWarning = 10;
        pressureFailure = 40;
        windowsCommitWarning = 85;
        windowsCommitFailure = 95;
        windowsPhysicalReserveBytes = windowsPhysicalReserve;
        wslVmCommitOverheadBytes = wslVmCommitOverhead;
        dateCommand = fixedDate now;
        meminfo = toString meminfo;
        cgroupRoot = toString cgroupRoot;
        procCgroup = toString procCgroup;
        procStatus = toString procStatus;
        cpuOnline = toString cpuOnline;
        pressureRoot = toString pressureRoot;
      };
    in
    if destination == null then
      probe
    else
      pkgs.writeShellScriptBin "workload-observation-for-destination" ''
        exec ${lib.getExe probe} ${lib.escapeShellArgs ([ destination ] ++ scopeParents)}
      '';
  contract = (mkWorkloadProbe { }).dotfilesObservationContract;

  outcome = id: ''(.outcomes[] | select(.id == "resource/workload/${id}") | .status)'';
  status = id: wanted: ''(${outcome id} == "${wanted}")'';
  message =
    id: pattern:
    ''(.outcomes[] | select(.id == "resource/workload/${id}") | .message | test("${pattern}"))'';
  field = name: expected: "(.resources[0].value.${name} == ${expected})";
  everyOutcome = wanted: ''all(.outcomes[]; .status == "${wanted}")'';
  limitsOf =
    limits:
    builtins.toJSON (
      map (limit: {
        inherit (limit) path;
        headroomBytes = limit.headroom;
        limitBytes = limit.limit;
        currentBytes = limit.current;
        workingSetBytes = limit.workingSet;
      }) limits
    );
  userManagerLimit = {
    path = "/user.slice/user-1000.slice";
    headroom = 320000000;
    limit = 400000000;
    current = 100000000;
    workingSet = 80000000;
  };
  userSliceLimit = {
    path = "/user.slice";
    headroom = 400000000;
    limit = 800000000;
    current = 500000000;
    workingSet = 400000000;
  };
  baselineLimits = limitsOf [
    userManagerLimit
    userSliceLimit
  ];
  noWindows = [
    (field "windowsCommitHeadroomBytes" "null")
    (field "windowsCommitGrowthBytes" "null")
    (field "windowsCommitRemainingBytes" "null")
    (field "windowsPhysicalAvailableBytes" "null")
    (field "windowsPhysicalHeadroomBytes" "null")
    (field "windowsCommitUsedPercent" "null")
    (field "windowsPhysicalReserveBytes" (toString windowsPhysicalReserve))
    (field "wslCap.configured.state" ''"unknown"'')
  ];
  unknownLimits = [
    (field "memoryLimits" "null")
    (field "memoryHeadroomBytes" "null")
    (status "cgroup-budget" "fail")
  ];
  windowsFresh = [
    (field "windowsCommitGrowthBytes" "null")
    (field "windowsCommitHeadroomBytes" "15032385536")
    (field "windowsCommitRemainingBytes" "21474836480")
    (field "windowsPhysicalAvailableBytes" "12884901888")
    (field "windowsPhysicalHeadroomBytes" "4294967296")
    (field "windowsPhysicalReserveBytes" (toString windowsPhysicalReserve))
    (field "windowsCommitUsedPercent" "50")
    (field "windows.state" ''"fresh"'')
    (field "windows.ageSeconds" "3")
    (field "windows.observedAt" (toString (now - 3)))
  ];
  windowsCase = reader: expected: {
    probe = mkWorkloadProbe { inherit reader; };
    inherit expected;
  };

  agentsSlice = "user.slice/user-1000.slice/agents.slice";
  acceptanceSlice = "${agentsSlice}/agents-acceptance.slice";
  # agents.slice と class の slice は上限を持たない階層で、その下に scope を置く
  withScopes =
    scopes: files:
    files
    // level agentsSlice { }
    // level acceptanceSlice { }
    // lib.foldl' (all: name: all // level "${acceptanceSlice}/${name}" scopes.${name}) { } (
      builtins.attrNames scopes
    );
  scopesOf =
    scopes:
    builtins.toJSON (
      map (scope: {
        path = "/${acceptanceSlice}/${scope.name}";
        currentBytes = scope.current;
        workingSetBytes = scope.workingSet;
      }) scopes
    );

  workloadCases = {
    baseline = {
      probe = mkWorkloadProbe { };
      expected = [
        (everyOutcome "pass")
        (field "observedAt" (toString now))
        (field "memoryTotalBytes" "1024000000")
        (field "memoryAvailableBytes" "614400000")
        (field "hostReserveBytes" "204800000")
        (field "hostReserveChargedBytes" "195200000")
        (field "hostMemoryHeadroomBytes" "419200000")
        (field "memoryLimits" baselineLimits)
        (field "memoryScopes" "[]")
        (field "memoryHeadroomBytes" "320000000")
        (field "cpuCount" "8")
        (field "cpuAffinityCount" "8")
        (field "cpuQuotaCpus" "null")
        (field "memoryFullAvg60" "9.99")
        (field "ioFullAvg60" "9.99")
      ]
      ++ windowsFresh;
    };
    host-binds = {
      probe = mkWorkloadProbe { meminfo = meminfoOf 1000000 300000; };
      expected = [
        (field "hostReserveChargedBytes" "0")
        (field "hostMemoryHeadroomBytes" "307200000")
        (field "memoryLimits" baselineLimits)
        (field "memoryHeadroomBytes" "307200000")
        (everyOutcome "pass")
      ];
    };
    aggregate-unreadable = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkTree "cgroup-other" (
          rootController
          // level "other.slice" {
            max = 2000000000;
            current = 1000000000;
          }
          // level "other.slice/job.scope" { }
        );
        procCgroup = pkgs.writeText "self-cgroup-other" "0::/other.slice/job.scope\n";
      };
      expected = [
        (field "hostReserveChargedBytes" "204800000")
        (field "hostMemoryHeadroomBytes" "409600000")
        (field "memoryLimits" (limitsOf [
          {
            path = "/other.slice";
            headroom = 1000000000;
            limit = 2000000000;
            current = 1000000000;
            workingSet = 1000000000;
          }
        ]))
        (field "memoryHeadroomBytes" "409600000")
        (status "cgroup-budget" "pass")
      ];
    };
    no-ancestor-limit = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkTree "cgroup-unlimited" (
          rootController
          // level "user.slice" userSlice
          // level "system.slice" { }
          // level "system.slice/svc.service" { }
        );
        procCgroup = pkgs.writeText "self-cgroup-unlimited" "0::/system.slice/svc.service\n";
      };
      expected = [
        (field "memoryLimits" "[]")
        (field "hostMemoryHeadroomBytes" "419200000")
        (field "memoryHeadroomBytes" "419200000")
        (status "cgroup-budget" "pass")
      ];
    };
    # 引数の cgroup は呼んだ process の居る場所ではなく、これから process を置く先。呼んだ process の cgroup が観測できなくても置き先で決まる
    destination-selects-the-chain = {
      probe = mkWorkloadProbe {
        procCgroup = pkgs.writeText "self-cgroup-elsewhere" "0::/system.slice/svc.service\n";
        destination = "/user.slice/user-1000.slice/agents.slice/agents-acceptance.slice";
      };
      expected = [
        (field "memoryLimits" baselineLimits)
        (field "memoryHeadroomBytes" "320000000")
        (status "cgroup-budget" "pass")
      ];
    };
    # 置き先の祖先が持つ上限も数える。置き先の slice が無い間は、存在する最も近い祖先から辿る
    destination-counts-the-limits-of-its-nearest-existing-ancestor = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          files =
            files:
            files
            // level "user.slice/user-1000.slice/agents.slice" {
              high = 200000000;
              current = 50000000;
            };
        };
        destination = "/user.slice/user-1000.slice/agents.slice/agents-acceptance.slice";
      };
      expected = [
        (field "memoryLimits" (limitsOf [
          {
            path = "/user.slice/user-1000.slice/agents.slice";
            headroom = 150000000;
            limit = 200000000;
            current = 50000000;
            workingSet = 50000000;
          }
          userManagerLimit
          userSliceLimit
        ]))
        (field "memoryHeadroomBytes" "150000000")
        (status "cgroup-budget" "pass")
      ];
    };
    # 不正な置き先は、制限なしとみなさず上限不明として止める
    destination-that-is-not-a-cgroup-path-is-unknown = {
      probe = mkWorkloadProbe { destination = "/user.slice/../system.slice"; };
      expected = unknownLimits;
    };
    # scope の working set は memoryLimits の階層と同じ式で求め、他に同じ式は置かない。負の reclaimable は 0 で、使用量を超えて引かない
    scopes-below-a-slice-are-reported-with-their-working-set = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          files = withScopes {
            "a.scope" = {
              current = 500000000;
              inactive = 50000000;
              active = 50000000;
              mapped = 200000000;
            };
            "b.scope" = {
              current = 300000000;
              inactive = 100000000;
              active = 100000000;
            };
            "c.scope" = { };
          };
        };
        destination = "/${acceptanceSlice}";
        scopeParents = [ "/${acceptanceSlice}" ];
      };
      expected = [
        (field "memoryLimits" baselineLimits)
        (field "memoryScopes" (scopesOf [
          {
            name = "a.scope";
            current = 500000000;
            workingSet = 500000000;
          }
          {
            name = "b.scope";
            current = 300000000;
            workingSet = 100000000;
          }
          {
            name = "c.scope";
            current = 0;
            workingSet = 0;
          }
        ]))
        (status "cgroup-budget" "pass")
      ];
    };
    # 使用量を読めない scope は載せない。載せない scope は、入場の判定が予約の全部を未使用と見る
    scope-with-unreadable-usage-is-not-reported = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          files =
            files:
            removeAttrs (withScopes {
              "a.scope" = {
                current = 500000000;
              };
              "d.scope" = {
                current = 100000000;
              };
            } files) [ "${acceptanceSlice}/d.scope/memory.stat" ];
        };
        destination = "/${acceptanceSlice}";
        scopeParents = [ "/${acceptanceSlice}" ];
      };
      expected = [
        (field "memoryScopes" (scopesOf [
          {
            name = "a.scope";
            current = 500000000;
            workingSet = 500000000;
          }
        ]))
        (status "cgroup-budget" "pass")
      ];
    };
    # 不正な親は、scope の使用量を求められないので上限不明として止める
    scope-parent-that-is-not-a-cgroup-path-is-unknown = {
      probe = mkWorkloadProbe {
        destination = "/${acceptanceSlice}";
        scopeParents = [ "/user.slice/../system.slice" ];
      };
      expected = unknownLimits;
    };
    controller-disabled-level = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          files =
            files:
            (removeAttrs files (
              map (name: "user.slice/user-1000.slice/session-3.scope/${name}") [
                "memory.max"
                "memory.high"
                "memory.current"
                "memory.stat"
              ]
            ))
            // {
              "user.slice/user-1000.slice/session-3.scope/cgroup.controllers" = "cpu\n";
            };
        };
      };
      expected = [
        (field "memoryLimits" baselineLimits)
        (field "memoryHeadroomBytes" "320000000")
        (status "cgroup-budget" "pass")
      ];
    };
    over-high = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          manager = {
            max = "max";
            high = 300000000;
            current = 350000000;
            inactive = 0;
          };
        };
      };
      expected = [
        (field "memoryLimits" (limitsOf [
          {
            path = "/user.slice/user-1000.slice";
            headroom = 0;
            limit = 300000000;
            current = 350000000;
            workingSet = 350000000;
          }
          userSliceLimit
        ]))
        (field "memoryHeadroomBytes" "0")
      ];
    };
    # 回収が重くなった場合の歯止めは memory full pressure の閾値なので、headroom を有限の memory.high の保証とみなす解釈は不可
    inactive-file-is-credited-as-reclaimable = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          manager = {
            current = 390000000;
            inactive = 300000000;
          };
        };
      };
      expected = [
        (field "memoryLimits" (limitsOf [
          {
            path = "/user.slice/user-1000.slice";
            headroom = 310000000;
            limit = 400000000;
            current = 390000000;
            workingSet = 90000000;
          }
          userSliceLimit
        ]))
        (field "memoryHeadroomBytes" "310000000")
        "(.resources[0].value.memoryLimits[0] | .limitBytes - .currentBytes) == 10000000"
      ];
    };
    # active な page cache を使用中と数えると、cache が上限まで増えた後は需要によらず入場できなくなる
    clean-active-file-is-credited-as-reclaimable = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          manager = {
            current = 390000000;
            inactive = 100000000;
            active = 200000000;
          };
        };
      };
      expected = [
        (field "memoryLimits" (limitsOf [
          {
            path = "/user.slice/user-1000.slice";
            headroom = 310000000;
            limit = 400000000;
            current = 390000000;
            workingSet = 90000000;
          }
          userSliceLimit
        ]))
      ];
    };
    # map 中、dirty、writeback 中の page は直ちに回収できないため、回収可能から引く
    pinned-file-is-not-credited = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          manager = {
            current = 390000000;
            inactive = 100000000;
            active = 200000000;
            mapped = 50000000;
            dirty = 30000000;
            writeback = 20000000;
          };
        };
      };
      expected = [
        (field "memoryLimits" (limitsOf [
          {
            path = "/user.slice/user-1000.slice";
            headroom = 210000000;
            limit = 400000000;
            current = 390000000;
            workingSet = 190000000;
          }
          userSliceLimit
        ]))
      ];
    };
    # map 中の page が file LRU の合計を超える場合に回収可能を負にすると、working set が使用量を超えて headroom を過小にする
    pinned-file-beyond-lru-credits-nothing = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          manager = {
            current = 390000000;
            inactive = 10000000;
            active = 10000000;
            mapped = 50000000;
          };
        };
      };
      expected = [
        (field "memoryLimits" (limitsOf [
          {
            path = "/user.slice/user-1000.slice";
            headroom = 10000000;
            limit = 400000000;
            current = 390000000;
            workingSet = 390000000;
          }
          userSliceLimit
        ]))
      ];
    };
    # 回収できない page の量が読めない階層を、全 cache を回収可能とみなして楽観にしない
    limit-without-pinned-file-split = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          files =
            files:
            files
            // {
              "user.slice/user-1000.slice/memory.stat" = "anon 1\ninactive_file 0\nactive_file 0\n";
            };
        };
      };
      expected = unknownLimits;
    };
    unknown-own-cgroup = {
      probe = mkWorkloadProbe { procCgroup = "/nonexistent/cgroup"; };
      expected = unknownLimits ++ [
        (field "hostMemoryHeadroomBytes" "419200000")
        (field "cpuCount" "null")
        (status "cpu" "fail")
      ];
    };
    unknown-hierarchy-root = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain { files = files: removeAttrs files [ "cgroup.controllers" ]; };
      };
      expected = unknownLimits;
    };
    limit-without-usage = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain { files = withoutFiles [ "memory.current" ]; };
      };
      expected = unknownLimits;
    };
    limit-without-reclaimable-split = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain { files = withoutFiles [ "memory.stat" ]; };
      };
      expected = unknownLimits;
    };
    enabled-controller-without-files = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          files = withoutFiles [
            "memory.max"
            "memory.high"
            "memory.current"
            "memory.stat"
          ];
        };
      };
      expected = unknownLimits;
    };
    malformed-limit = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          manager.max = "unlimited";
        };
      };
      expected = unknownLimits;
    };
    meminfo-unreadable = {
      probe = mkWorkloadProbe {
        meminfo = "/nonexistent/meminfo";
        declaredMemoryBytes = 2000000000;
      };
      expected = [
        (field "memoryTotalBytes" "null")
        (field "memoryAvailableBytes" "null")
        (field "hostMemoryHeadroomBytes" "null")
        (field "hostReserveBytes" "null")
        (field "memoryHeadroomBytes" "null")
        (status "linux-memory" "fail")
        (status "wsl-cap" "fail")
        (status "windows-memory" "pass")
      ];
    };
    available-above-total = {
      probe = mkWorkloadProbe { meminfo = meminfoOf 1000000 1000001; };
      expected = [
        (field "memoryTotalBytes" "1024000000")
        (field "memoryAvailableBytes" "null")
        (field "hostMemoryHeadroomBytes" "null")
        (field "memoryHeadroomBytes" "null")
        (status "linux-memory" "fail")
      ];
    };
    pressure-warning-edge = {
      probe = mkWorkloadProbe { pressureRoot = mkPressure "10.00" "39.99"; };
      expected = [
        (status "memory-pressure" "warn")
        (status "io-pressure" "warn")
        (field "memoryFullAvg60" "10")
        (field "ioFullAvg60" "39.99")
      ];
    };
    pressure-failure-edge = {
      probe = mkWorkloadProbe { pressureRoot = mkPressure "40.00" "9.99"; };
      expected = [
        (status "memory-pressure" "fail")
        (status "io-pressure" "pass")
      ];
    };
    pressure-unreadable = {
      probe = mkWorkloadProbe { pressureRoot = "/nonexistent/pressure"; };
      expected = [
        (status "memory-pressure" "fail")
        (status "io-pressure" "fail")
        (field "memoryFullAvg60" "null")
        (field "ioFullAvg60" "null")
      ];
    };
    cpu-quota-below-affinity = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain { aggregate.cpuMax = "150000 100000"; };
      };
      expected = [
        (field "cpuCount" "1")
        (field "cpuAffinityCount" "8")
        (field "cpuQuotaCpus" "1.5")
        (status "cpu" "pass")
      ];
    };
    cpu-tightest-quota = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain {
          aggregate.cpuMax = "200000 100000";
          manager.cpuMax = "400000 100000";
        };
      };
      expected = [
        (field "cpuCount" "2")
        (field "cpuQuotaCpus" "2")
      ];
    };
    cpu-quota-above-affinity = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain { aggregate.cpuMax = "1600000 100000"; };
      };
      expected = [
        (field "cpuCount" "8")
        (field "cpuQuotaCpus" "16")
      ];
    };
    cpu-fractional-quota = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain { aggregate.cpuMax = "50000 100000"; };
      };
      expected = [
        (field "cpuCount" "1")
        (field "cpuQuotaCpus" "0.5")
      ];
    };
    cpu-quota-unreadable = {
      probe = mkWorkloadProbe {
        cgroupRoot = mkChain { aggregate.cpuMax = "garbage"; };
      };
      expected = [
        (field "cpuCount" "null")
        (status "cpu" "fail")
        (field "memoryHeadroomBytes" "320000000")
      ];
    };
    cpu-affinity-missing = {
      probe = mkWorkloadProbe {
        procStatus = pkgs.writeText "status-without-affinity" "Name:\tbash\n";
      };
      expected = [
        (field "cpuCount" "null")
        (field "cpuAffinityCount" "null")
        (status "cpu" "fail")
      ];
    };
    cap-consistent = {
      probe = mkWorkloadProbe {
        declaredMemoryBytes = 51539607552;
        declaredProcessors = 12;
      };
      expected = [
        (status "wsl-cap" "pass")
        (field "wslCap.findings" "[]")
        (field "wslCap.declared" ''{"memoryBytes":51539607552,"processors":12}'')
        (field "wslCap.configured" ''{"state":"read","memoryBytes":51539607552,"processors":12}'')
        (field "wslCap.effective" ''{"memoryBytes":1024000000,"processors":12}'')
      ];
    };
    cap-undeclared = {
      probe = mkWorkloadProbe { };
      expected = [
        (status "wsl-cap" "pass")
        (message "wsl-cap" "no WSL memory or processor cap is declared")
        (field "wslCap.findings" "[]")
      ];
    };
    cap-configuration-differs-from-declaration = {
      probe = mkWorkloadProbe {
        declaredMemoryBytes = 42949672960;
        declaredProcessors = 12;
      };
      expected = [
        (status "wsl-cap" "warn")
        (message "wsl-cap" "diagnosis only")
        (field "wslCap.findings" ''["configuredMemoryDiffersFromDeclared"]'')
        (status "windows-memory" "pass")
        (field "memoryHeadroomBytes" "320000000")
      ];
    };
    cap-vm-not-restarted = {
      probe = mkWorkloadProbe {
        reader = readerFor "cap-restart" (
          freshRecord
          // {
            wslConfig = {
              state = "read";
              memoryBytes = 1000000;
              processors = 4;
            };
          }
        );
        declaredMemoryBytes = 1000000;
        declaredProcessors = 4;
      };
      expected = [
        (status "wsl-cap" "warn")
        (field "wslCap.findings" ''["effectiveMemoryExceedsConfigured","effectiveProcessorsExceedConfigured"]'')
      ];
    };
    cap-configuration-missing = {
      probe = mkWorkloadProbe {
        reader = readerFor "cap-missing" (
          freshRecord
          // {
            wslConfig = {
              state = "missing";
              memoryBytes = null;
              processors = null;
            };
          }
        );
        declaredMemoryBytes = 42949672960;
      };
      expected = [
        (status "wsl-cap" "warn")
        (field "wslCap.findings" ''["configuredMemoryDiffersFromDeclared"]'')
        (field "wslCap.configured.state" ''"missing"'')
      ];
    };
    cap-configuration-unreadable = {
      probe = mkWorkloadProbe {
        reader = readerFor "cap-unreadable" (
          freshRecord
          // {
            wslConfig = {
              state = "unreadable";
              memoryBytes = null;
              processors = null;
            };
          }
        );
        declaredMemoryBytes = 1000000;
      };
      expected = [
        (status "wsl-cap" "warn")
        (field "wslCap.findings" ''["effectiveMemoryExceedsDeclared"]'')
        (field "wslCap.configured.state" ''"unreadable"'')
      ];
    };
    cap-snapshot-unavailable = {
      probe = mkWorkloadProbe {
        reader = missingReader;
        declaredMemoryBytes = 1000000;
      };
      expected = [
        (status "wsl-cap" "warn")
        (field "wslCap.findings" ''["effectiveMemoryExceedsDeclared"]'')
        (field "wslCap.configured.state" ''"unknown"'')
        (status "windows-memory" "fail")
      ];
    };
    cap-effective-unverifiable = {
      probe = mkWorkloadProbe {
        cpuOnline = "/nonexistent/online";
        declaredProcessors = 12;
      };
      expected = [
        (status "wsl-cap" "fail")
        (field "wslCap.effective.processors" "null")
      ];
    };
    windows-stale = windowsCase (readerFor "workload-stale" (record (now - maximumAge - 1))) (
      noWindows
      ++ [
        (status "windows-memory" "fail")
        (message "windows-memory" "stale")
        (field "windows.state" ''"stale"'')
        (field "windows.ageSeconds" (toString (maximumAge + 1)))
      ]
    );
    windows-future = windowsCase (readerFor "workload-future" (record (now + futureSkew + 1))) (
      noWindows
      ++ [
        (status "windows-memory" "fail")
        (message "windows-memory" "in the future")
        (field "windows.state" ''"future"'')
      ]
    );
    windows-invalid = windowsCase (readerFor "workload-invalid" invalidRecords.truncated) (
      noWindows
      ++ [
        (status "windows-memory" "fail")
        (message "windows-memory" "not a valid record")
        (field "windows.state" ''"invalid"'')
        (field "windows.ageSeconds" "null")
        (field "windows.observedAt" "null")
      ]
    );
    windows-unavailable = windowsCase missingReader (
      noWindows
      ++ [
        (status "windows-memory" "fail")
        (message "windows-memory" "unavailable")
        (field "windows.state" ''"unavailable"'')
        (field "memoryHeadroomBytes" "320000000")
      ]
    );
    windows-physical-below-reserve = {
      probe = mkWorkloadProbe {
        reader = readerFor "workload-low-physical" (
          freshRecord // { physicalAvailableBytes = 4294967296; }
        );
      };
      expected = [
        (field "windowsPhysicalAvailableBytes" "4294967296")
        (field "windowsPhysicalHeadroomBytes" "0")
        (field "windowsCommitHeadroomBytes" "15032385536")
        (status "windows-memory" "pass")
      ];
    };
    # VM が増やせる commit の上限は、稼働中の guest の MemTotal（この probe では 1024000000）に overhead の 2147483648 を足し、VM の commit を引いた値
    commit-growth-from-the-running-vm = {
      probe = mkWorkloadProbe { reader = readerFor "workload-vm-room" (vmCommitRecord 1500000000); };
      expected = [
        (field "windowsCommitGrowthBytes" "1671483648")
        (field "windowsCommitHeadroomBytes" "15032385536")
        (field "memoryTotalBytes" "1024000000")
        (field "windows.state" ''"fresh"'')
      ];
    };
    commit-growth-last-byte = {
      probe = mkWorkloadProbe { reader = readerFor "workload-vm-last-byte" (vmCommitRecord 3171483647); };
      expected = [ (field "windowsCommitGrowthBytes" "1") ];
    };
    commit-growth-clamps-at-zero = {
      probe = mkWorkloadProbe { reader = readerFor "workload-vm-over" (vmCommitRecord 4000000000); };
      expected = [
        (field "windowsCommitGrowthBytes" "0")
        (field "windowsCommitHeadroomBytes" "15032385536")
      ];
    };
    # .wslconfig だけが先に下がった状態でも、稼働中の VM から求めた値は変わらない
    commit-growth-ignores-a-lowered-wslconfig = {
      probe = mkWorkloadProbe {
        reader = readerFor "workload-vm-lowered-config" (
          vmCommitRecord 1500000000
          // {
            wslConfig = wslConfigRead // {
              memoryBytes = 536870912;
            };
          }
        );
      };
      expected = [
        (field "windowsCommitGrowthBytes" "1671483648")
        (field "wslCap.configured.memoryBytes" "536870912")
      ];
    };
    commit-growth-ignores-an-unreadable-wslconfig = {
      probe = mkWorkloadProbe {
        reader = readerFor "workload-vm-unreadable-config" (
          vmCommitRecord 1500000000
          // {
            wslConfig = {
              state = "unreadable";
              memoryBytes = null;
              processors = null;
            };
          }
        );
      };
      expected = [
        (field "windowsCommitGrowthBytes" "1671483648")
        (field "wslCap.configured.state" ''"unreadable"'')
      ];
    };
    commit-growth-unknown-without-the-vm-commit = {
      probe = mkWorkloadProbe { reader = readerFor "workload-vm-null" (vmCommitRecord null); };
      expected = [
        (field "windowsCommitGrowthBytes" "null")
        (field "windowsCommitHeadroomBytes" "15032385536")
      ];
    };
    commit-growth-unknown-while-the-snapshot-is-stale = {
      probe = mkWorkloadProbe {
        reader = readerFor "workload-vm-stale" (
          record (now - maximumAge - 1) // { wslVmCommitBytes = 1500000000; }
        );
      };
      expected = [
        (field "windowsCommitGrowthBytes" "null")
        (field "windows.state" ''"stale"'')
      ];
    };
    commit-growth-unknown-without-the-guest-memory = {
      probe = mkWorkloadProbe {
        reader = readerFor "workload-vm-no-guest-memory" (vmCommitRecord 1500000000);
        meminfo = "/nonexistent/meminfo";
      };
      expected = [
        (field "memoryTotalBytes" "null")
        (field "windowsCommitGrowthBytes" "null")
      ];
    };
  };

  commitThresholdCase = used: limit: percent: wanted: safe: remaining: {
    probe = mkWorkloadProbe {
      reader = readerFor "workload-${toString used}-${toString limit}" (commitRecord used limit);
    };
    consumer = mkCommitProbe (
      readerFor "consumer-${toString used}-${toString limit}" (commitRecord used limit)
    );
    expected = [
      (status "windows-memory" wanted)
      (field "windowsCommitUsedPercent" percent)
      (field "windowsCommitHeadroomBytes" (toString safe))
      (field "windowsCommitRemainingBytes" (toString remaining))
      (field "windows.state" ''"fresh"'')
    ];
  };
  windowsThresholdCases = {
    below-warning = commitThresholdCase 849 1000 "84" "pass" 1 151;
    warning = commitThresholdCase 850 1000 "85" "warn" 0 150;
    below-failure = commitThresholdCase 949 1000 "94" "warn" 0 51;
    failure = commitThresholdCase 950 1000 "95" "fail" 0 50;
    over-limit = commitThresholdCase 50000 40000 "100" "fail" 0 0;
    sized-below-warning = commitThresholdCase 36077725286 42949672960 "83" "pass" 429496730 6871947674;
  };

  mkWslMemoryProbe =
    pressureRoot:
    mkWslMemory {
      inherit pkgs lib pressureRoot;
      journalTimeoutSeconds = 1;
      pressureWarning = 10;
      pressureFailure = 40;
      relayMinimumAgeSeconds = 300;
      journalctlCommand = failingCommand;
      psCommand = failingCommand;
      zoneinfo = "/nonexistent/zoneinfo";
      buddyinfo = "/nonexistent/buddyinfo";
    };
  pressureCases = {
    calm = {
      memory = "0.00";
      io = "0.00";
      expected = {
        memory-pressure = "pass";
        io-pressure = "pass";
      };
    };
    below-warning = {
      memory = "9.99";
      io = "9.99";
      expected = {
        memory-pressure = "pass";
        io-pressure = "pass";
      };
    };
    warning-edge = {
      memory = "10.00";
      io = "39.99";
      expected = {
        memory-pressure = "warn";
        io-pressure = "warn";
      };
    };
    failure-edge = {
      memory = "39.99";
      io = "40.00";
      expected = {
        memory-pressure = "warn";
        io-pressure = "fail";
      };
    };
    failing-memory = {
      memory = "40.00";
      io = "10.00";
      expected = {
        memory-pressure = "fail";
        io-pressure = "warn";
      };
    };
    saturated = {
      memory = "99.99";
      io = "0.01";
      expected = {
        memory-pressure = "fail";
        io-pressure = "pass";
      };
    };
  };

  mkFakePowerShell =
    name: body:
    pkgs.writeShellScript name ''
      set -euo pipefail

      ${body}
    '';
  fakeWslpath = pkgs.writeShellScript "wslpath-fixture" ''
    test "$#" -eq 2
    test "$1" = -w
    printf 'WIN:%s\n' "$2"
  '';
  collectorSnapshotPath = "/mnt/c/ProgramData/dotfiles-resource-observation/windows-memory.json";
  collectorFutureTime = 4102444800;
  collectorReader =
    name: time: content:
    mkReaderProbe {
      snapshotPath = collectorSnapshotPath;
      inherit time;
      headCommand = pkgs.writeShellScript "head-${name}" "exec ${pkgs.coreutils}/bin/cat ${snapshotFile name content}";
    };
  publishedReader = collectorReader "collector-published" collectorFutureTime (
    record collectorFutureTime
  );
  preexistingReader = collectorReader "collector-preexisting" now (record (now - 3));
  staleCollectorReader = collectorReader "collector-stale" now (record (now - maximumAge - 1));
  mkCli =
    {
      reader,
      powershell,
      operationTimeoutSeconds ? 5,
    }:
    mkCollector {
      inherit
        pkgs
        lib
        reader
        operationTimeoutSeconds
        ;
      powershellCommand = powershell;
      intervalSeconds = 10;
      publishWaitSeconds = 1;
      wslpathCommand = fakeWslpath;
    };
  healthyStatus = {
    directoryTrusted = true;
    collectorInstalled = true;
    collectorCurrent = true;
    taskRegistered = true;
    taskOwned = true;
    taskState = "Running";
  };
  healthyPowerShell = mkFakePowerShell "powershell-healthy" "printf '%s\\r\\n' ${lib.escapeShellArg (builtins.toJSON healthyStatus)}";
  hangingPowerShell = mkFakePowerShell "powershell-hanging" "exec ${pkgs.coreutils}/bin/sleep 30";
  healthyCli = mkCli {
    reader = publishedReader;
    powershell = healthyPowerShell;
  };
  cliVariants = {
    preexisting = mkCli {
      reader = preexistingReader;
      powershell = healthyPowerShell;
    };
    hanging = mkCli {
      reader = publishedReader;
      powershell = hangingPowerShell;
      operationTimeoutSeconds = 1;
    };
    stale = mkCli {
      reader = staleCollectorReader;
      powershell = healthyPowerShell;
    };
  };
in
{
  source = [
    {
      windows-snapshot-reader-contract =
        pkgs.runCommandLocal "check-windows-snapshot-reader-contract" { nativeBuildInputs = [ pkgs.jq ]; }
          ''
            set -euo pipefail

            assert_snapshot() {
              local name=$1 command=$2 filter=$3 output
              if ! output=$("$command"); then
                echo "reader $name did not classify its snapshot" >&2
                return 1
              fi
              if ! jq -e "$filter" <<<"$output" >/dev/null; then
                echo "reader $name reported $output" >&2
                return 1
              fi
            }

            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                name: case:
                "assert_snapshot ${lib.escapeShellArg name} ${lib.getExe case.reader} ${lib.escapeShellArg case.filter}"
              ) readerCases
            )}
            touch "$out"
          '';

      windows-memory-commit-consumer-contract =
        pkgs.runCommandLocal "check-windows-memory-commit-consumer-contract" { }
          ''
            set -euo pipefail

            assert_percent() {
              local name=$1 command=$2 expected=$3 output
              output=$("$command" 2>"$TMPDIR/$name.stderr")
              if [[ $output != "$expected" || -s $TMPDIR/$name.stderr ]]; then
                echo "$name reported '$output' instead of $expected" >&2
                return 1
              fi
            }
            assert_unknown() {
              local name=$1 command=$2 status=0
              "$command" >"$TMPDIR/$name.stdout" 2>"$TMPDIR/$name.stderr" || status=$?
              if ((status != 1)) || [[ -s $TMPDIR/$name.stdout || -s $TMPDIR/$name.stderr ]]; then
                echo "$name must exit 1 without output, exited $status" >&2
                return 1
              fi
            }

            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                name: case: "assert_percent ${name} ${lib.getExe (mkCommitProbe case.reader)} ${case.percent}"
              ) commitCases
            )}
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                name: reader: "assert_unknown ${name} ${lib.getExe (mkCommitProbe reader)}"
              ) commitFailures
            )}
            touch "$out"
          '';

      workload-observation-contract =
        pkgs.runCommandLocal "check-workload-observation-contract" { nativeBuildInputs = [ pkgs.jq ]; }
          ''
            set -euo pipefail

            contract=${lib.escapeShellArg (builtins.toJSON contract)}

            assert_workload() {
              local name=$1 command=$2 filter=$3 consumer=$4 stdout="$TMPDIR/$1.stdout"
              if ! "$command" >"$stdout" 2>"$TMPDIR/$name.stderr" || [[ -s $TMPDIR/$name.stderr ]]; then
                echo "workload $name did not produce a clean envelope" >&2
                cat "$TMPDIR/$name.stderr" >&2
                return 1
              fi
              if ! jq -e --argjson contract "$contract" '
                (keys | sort) == ["outcomes", "resources", "schemaVersion"]
                and .schemaVersion == $contract.envelopeVersion
                and ([.outcomes[].id] | sort) == ($contract.requiredOutcomeIds | sort)
                and all(.outcomes[]; (.message | length) > 0 and (.status | IN("pass", "warn", "fail")))
                and (.resources | length) == 1
                and .resources[0].key == $contract.requiredResourceKeys[0]
                and (.resources[0].value | . as $value
                  | ["memoryAvailableBytes", "memoryTotalBytes", "cpuCount", "memoryHeadroomBytes",
                     "hostMemoryHeadroomBytes", "memoryLimits", "windowsCommitHeadroomBytes",
                     "windowsCommitGrowthBytes", "windowsPhysicalAvailableBytes", "observedAt"]
                  | all(. as $key | $value | has($key)))
              ' "$stdout" >/dev/null; then
                echo "workload $name violated the envelope contract" >&2
                cat "$stdout" >&2
                return 1
              fi
              if ! jq -e "$filter" "$stdout" >/dev/null; then
                echo "workload $name reported an unexpected observation" >&2
                cat "$stdout" >&2
                return 1
              fi
              if [[ -n $consumer ]]; then
                if [[ $("$consumer") != "$(jq -r '.resources[0].value.windowsCommitUsedPercent' "$stdout")" ]]; then
                  echo "workload $name disagrees with the committed-memory consumer" >&2
                  return 1
                fi
              fi
            }

            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                name: case:
                "assert_workload ${name} ${lib.getExe case.probe} ${lib.escapeShellArg (lib.concatStringsSep " and " case.expected)} ''"
              ) workloadCases
            )}
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                name: case:
                "assert_workload windows-${name} ${lib.getExe case.probe} ${lib.escapeShellArg (lib.concatStringsSep " and " case.expected)} ${lib.getExe case.consumer}"
              ) windowsThresholdCases
            )}
            touch "$out"
          '';

      workload-pressure-consistency =
        pkgs.runCommandLocal "check-workload-pressure-consistency" { nativeBuildInputs = [ pkgs.jq ]; }
          ''
            set -euo pipefail

            summary='{
              statuses: ([.outcomes[] | select(.id | endswith("-pressure")) | {key: (.id | split("/") | last), value: .status}] | from_entries),
              memory: .resources[0].value.memoryFullAvg60,
              io: .resources[0].value.ioFullAvg60
            }'

            assert_consistent() {
              local name=$1 wsl=$2 workload=$3 expected=$4
              "$wsl" >"$TMPDIR/$name.wsl"
              "$workload" >"$TMPDIR/$name.workload"
              if [[ $(jq -cS "$summary" "$TMPDIR/$name.wsl") != "$(jq -cS "$summary" "$TMPDIR/$name.workload")" ]]; then
                echo "pressure $name is judged differently by the WSL memory and workload observations" >&2
                return 1
              fi
              if ! jq -e --argjson expected "$expected" '.statuses == $expected' <(jq -c "$summary" "$TMPDIR/$name.workload") >/dev/null; then
                echo "pressure $name is not judged with the declared thresholds" >&2
                return 1
              fi
            }

            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                name: case:
                let
                  pressureRoot = mkPressure case.memory case.io;
                in
                "assert_consistent ${name} ${lib.getExe (mkWslMemoryProbe pressureRoot)} ${
                  lib.getExe (mkWorkloadProbe {
                    inherit pressureRoot;
                  })
                } ${lib.escapeShellArg (builtins.toJSON case.expected)}"
              ) pressureCases
            )}
            assert_consistent unreadable ${lib.getExe (mkWslMemoryProbe "/nonexistent/pressure")} ${
              lib.getExe (mkWorkloadProbe {
                pressureRoot = "/nonexistent/pressure";
              })
            } '{"memory-pressure":"fail","io-pressure":"fail"}'
            touch "$out"
          '';

      windows-collector-cli-contract =
        pkgs.runCommandLocal "check-windows-collector-cli-contract" { nativeBuildInputs = [ pkgs.jq ]; }
          ''
            set -euo pipefail

            run() {
              local name=$1 expected=$2 status=0
              shift 2
              "$@" >"$TMPDIR/$name.stdout" 2>"$TMPDIR/$name.stderr" || status=$?
              if [[ $status != "$expected" ]]; then
                echo "$name exited $status instead of $expected" >&2
                cat "$TMPDIR/$name.stdout" "$TMPDIR/$name.stderr" >&2
                return 1
              fi
            }

            run install 0 ${lib.getExe healthyCli} install
            jq -e '.state == "fresh"' "$TMPDIR/install.stdout" >/dev/null

            run install-leftover-snapshot 1 ${lib.getExe cliVariants.preexisting} install
            run install-hanging 1 timeout 30 ${lib.getExe cliVariants.hanging} install

            run status-stale 1 ${lib.getExe cliVariants.stale} status
            jq -e '.snapshot.state == "stale"' "$TMPDIR/status-stale.stdout" >/dev/null
            touch "$out"
          '';
    }
  ];
}
