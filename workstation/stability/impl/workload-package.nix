{
  pkgs,
  lib,
  reader,
  hostReservePercent,
  aggregateCgroup,
  pressureWarning,
  pressureFailure,
  windowsCommitWarning,
  windowsCommitFailure,
  windowsPhysicalReserveBytes,
  declaredMemoryBytes ? null,
  declaredProcessors ? null,
  awkCommand ? lib.getExe pkgs.gawk,
  cgroupRoot ? "/sys/fs/cgroup",
  cpuOnline ? "/sys/devices/system/cpu/online",
  dateCommand ? "${pkgs.coreutils}/bin/date",
  jqCommand ? lib.getExe pkgs.jq,
  meminfo ? "/proc/meminfo",
  pressureRoot ? "/proc/pressure",
  procCgroup ? "/proc/self/cgroup",
  procStatus ? "/proc/self/status",
  timeoutCommand ? "${pkgs.coreutils}/bin/timeout",
}:

let
  name = "dotfiles-observe-workload";
  outcomeIds = {
    linuxMemory = "resource/workload/linux-memory";
    cgroupBudget = "resource/workload/cgroup-budget";
    cpu = "resource/workload/cpu";
    memoryPressure = "resource/workload/memory-pressure";
    ioPressure = "resource/workload/io-pressure";
    windowsMemory = "resource/workload/windows-memory";
    wslCap = "resource/workload/wsl-cap";
  };
  readerTimeoutSeconds = reader.dotfilesWindowsSnapshot.outerTimeout;
  contract = {
    envelopeVersion = 1;
    allowedOutcomeIds = builtins.attrValues outcomeIds;
    requiredOutcomeIds = builtins.attrValues outcomeIds;
    requiredResourceKeys = [ "workload" ];
    outerTimeout = readerTimeoutSeconds + 5;
  };
  substitutions = {
    "@aggregateCgroup@" = lib.escapeShellArg aggregateCgroup;
    "@awkCommand@" = lib.escapeShellArg awkCommand;
    "@cgroupBudgetOutcome@" = lib.escapeShellArg outcomeIds.cgroupBudget;
    "@cgroupRoot@" = lib.escapeShellArg cgroupRoot;
    "@cpuOnline@" = lib.escapeShellArg cpuOnline;
    "@cpuOutcome@" = lib.escapeShellArg outcomeIds.cpu;
    "@dateCommand@" = lib.escapeShellArg dateCommand;
    "@declaredMemoryBytes@" = toString declaredMemoryBytes;
    "@declaredProcessors@" = toString declaredProcessors;
    "@envelopeVersion@" = toString contract.envelopeVersion;
    "@hostReservePercent@" = toString hostReservePercent;
    "@ioPressureOutcome@" = lib.escapeShellArg outcomeIds.ioPressure;
    "@jqCommand@" = lib.escapeShellArg jqCommand;
    "@linuxMemoryOutcome@" = lib.escapeShellArg outcomeIds.linuxMemory;
    "@memoryPressureOutcome@" = lib.escapeShellArg outcomeIds.memoryPressure;
    "@meminfo@" = lib.escapeShellArg meminfo;
    "@pressureFailure@" = toString pressureFailure;
    "@pressureRoot@" = lib.escapeShellArg pressureRoot;
    "@pressureWarning@" = toString pressureWarning;
    "@procCgroup@" = lib.escapeShellArg procCgroup;
    "@procStatus@" = lib.escapeShellArg procStatus;
    "@readerCommand@" = lib.escapeShellArg (lib.getExe reader);
    "@readerTimeoutSeconds@" = toString readerTimeoutSeconds;
    "@timeoutCommand@" = lib.escapeShellArg timeoutCommand;
    "@windowsCommitFailure@" = toString windowsCommitFailure;
    "@windowsCommitWarning@" = toString windowsCommitWarning;
    "@windowsMemoryOutcome@" = lib.escapeShellArg outcomeIds.windowsMemory;
    "@windowsPhysicalReserveBytes@" = toString windowsPhysicalReserveBytes;
    "@wslCapOutcome@" = lib.escapeShellArg outcomeIds.wslCap;
  };
in
assert lib.assertMsg (
  pressureWarning < pressureFailure
) "PSI warning threshold must be below failure";
assert lib.assertMsg (
  windowsCommitWarning < windowsCommitFailure
) "Windows commit warning threshold must be below failure";
assert lib.assertMsg (
  builtins.isInt hostReservePercent && hostReservePercent >= 1 && hostReservePercent <= 99
) "host reserve must be a percentage from 1 to 99";
assert lib.assertMsg (
  builtins.isInt windowsPhysicalReserveBytes && windowsPhysicalReserveBytes > 0
) "the Windows physical memory reserve must be a positive byte count";
assert lib.assertMsg (
  builtins.match "/[A-Za-z0-9_.@:-]+(/[A-Za-z0-9_.@:-]+)*" aggregateCgroup != null
) "aggregate cgroup must be an absolute cgroup path below the root";
assert lib.assertMsg (
  declaredMemoryBytes == null || (builtins.isInt declaredMemoryBytes && declaredMemoryBytes > 0)
) "declared WSL memory must be null or a positive byte count";
assert lib.assertMsg (
  declaredProcessors == null || (builtins.isInt declaredProcessors && declaredProcessors > 0)
) "declared WSL processors must be null or a positive count";
(pkgs.writeShellApplication {
  inherit name;
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./observe-workload.sh);
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      mainProgram = name;
    };
    passthru = (old.passthru or { }) // {
      dotfilesObservationCommandKind = "normalized-protocol";
      dotfilesObservationContract = contract;
    };
  })
