{ pkgs }:

let
  mkDedicatedCommand =
    kind:
    (pkgs.writeShellApplication {
      name = "fixture-${kind}-command";
      text = "exit 0";
    }).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          dotfilesObservationCommandKind = kind;
        };
      });
  numericCommand = mkDedicatedCommand "numeric-command-threshold";
  normalizedProtocolCommand = mkDedicatedCommand "normalized-protocol";
  cmdExecutable = pkgs.writeShellApplication {
    name = "cmd.exe";
    text = "exit 0";
  };
  renamedExecutable = pkgs.writeShellApplication {
    name = "renamed-shell";
    text = "exec ${pkgs.bash}/bin/bash \"$@\"";
  };
  mkMarkedText =
    name: meta:
    (pkgs.writeText name "not an executable package").overrideAttrs (old: {
      inherit meta;
      passthru = (old.passthru or { }) // {
        dotfilesObservationCommandKind = "numeric-command-threshold";
      };
    });
  markedTextMissingMainProgram = mkMarkedText "missing-main-program" { };
  markedTextEmptyMainProgram = mkMarkedText "empty-main-program" { mainProgram = ""; };
  markedTextUnsafeMainProgram = mkMarkedText "unsafe-main-program" {
    mainProgram = "../escape";
  };

  common = id: {
    checkId = "fixture/${id}";
    resourceKey = "fixture-${id}";
    timeoutSeconds = 10;
    failureMessage = "fixture ${id} failed";
  };

  valid = {
    "host/roster" = common "roster" // {
      kind = "roster";
      members = [ "fixture" ];
      minimumCount = 1;
      failureOnly = false;
    };
    "host/path-match" = common "path-match" // {
      kind = "path-match";
      currentPath = "/run/current-system";
      requiredPath = "/nix/var/nix/profiles/system";
      resolution = "canonical";
    };
    "host/command-version" = common "command-version" // {
      kind = "command-version";
      path = "/run/current-system/sw/bin/nix";
      versionArgs = [ "--version" ];
      expectedSource = "/run/current-system/sw/bin/nix";
    };
    "host/release-tree" = common "release-tree" // {
      kind = "release-tree";
      visiblePath = "/home/fixture/.local/bin/fixture";
      visibleTarget = "../share/dotfiles/agents/fixture/current/bin/fixture";
      currentLink = "/home/fixture/.local/share/dotfiles/agents/fixture/current";
      releasesRoot = "/home/fixture/.local/share/dotfiles/agents/fixture/releases";
      entrypoint = "bin/fixture";
      requiredPaths = {
        "bin/fixture" = {
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
    "host/deployed-path" = common "deployed-path" // {
      kind = "deployed-path";
      source = "/nix/store/fixture-source";
      destination = "/home/fixture/.config/fixture";
      acceptedDestinationKinds = [
        "regular-file"
        "symlink"
      ];
    };
    "host/path-metadata" = common "path-metadata" // {
      kind = "path-metadata";
      path = "/run/secrets/fixture";
      owner = "root";
      group = "root";
      mode = "0400";
    };
    "host/managed-roots" = common "managed-roots" // {
      kind = "managed-roots";
      paths = [ "/home/fixture/.cache/dotfiles-wsl" ];
      missingAsZero = true;
      oneFileSystem = true;
      cachePolicy = "allocated-bytes";
    };
    "host/systemd-service" = common "systemd-service" // {
      kind = "systemd-service";
      unit = "fixture.service";
      loadStates = [ "loaded" ];
      activeStates = [ "active" ];
      results = [ "success" ];
    };
    "host/systemd-timer" = common "systemd-timer" // {
      kind = "systemd-timer";
      timer = "fixture.timer";
      service = "fixture.service";
      unitFileStates = [
        "enabled"
        "enabled-runtime"
      ];
      activeStates = [ "active" ];
      serviceResults = [ "success" ];
    };
    "host/restart-counter" = common "restart-counter" // {
      kind = "restart-counter";
      sourceKind = "systemd-service";
      target = "fixture.service";
      warningAt = 5;
      failureAt = 20;
    };
    "host/filesystem-threshold" = common "filesystem-threshold" // {
      kind = "filesystem-threshold";
      path = "/";
      metric = "used-percent";
      warning = 85;
      failure = 95;
    };
    "host/numeric-command-threshold" = common "numeric-command-threshold" // {
      kind = "numeric-command-threshold";
      command = numericCommand;
      metric = "free-percent";
      warning = 15;
      failure = 10;
    };
    "host/swap-policy" = common "swap-policy" // {
      kind = "swap-policy";
      minimumTotalBytes = 8589934592;
      requiredZramAlgorithm = "lzo-rle";
      requireZram = true;
      zramAboveDisk = true;
    };
    "host/journal-size" = common "journal-size" // {
      kind = "journal-size";
      maximumBytes = 4294967296;
    };
    "host/container-image" = common "container-image" // {
      kind = "container-image";
      container = "fixture";
      image = "registry.example.invalid/fixture@sha256:0123456789abcdef";
    };
    "host/http-health" = common "http-health" // {
      kind = "http-health";
      method = "GET";
      url = "http://127.0.0.1:8080/health";
    };
    "host/normalized-protocol" = common "normalized-protocol" // {
      kind = "normalized-protocol";
      command = normalizedProtocolCommand;
      allowedOutcomeIds = [
        "ready"
        "unavailable"
      ];
      requiredOutcomeIds = [ "ready" ];
      requiredResourceKeys = [
        "summary"
        "version"
      ];
      envelopeVersion = 1;
    };
  };

  replace = name: value: valid // { ${name} = value; };
  restartCounter = valid."host/restart-counter";
  numericThreshold = valid."host/numeric-command-threshold";
  normalizedProtocol = valid."host/normalized-protocol";
in
{
  inherit valid;

  invalid = {
    unknownKind = replace "host/roster" (valid."host/roster" // { kind = "shell"; });
    missingRequired = replace "host/roster" (builtins.removeAttrs valid."host/roster" [ "members" ]);
    extraField = replace "host/roster" (valid."host/roster" // { probe = "anything"; });
    wrongType = replace "host/roster" (valid."host/roster" // { members = "fixture"; });
    timeoutBelowRange = replace "host/roster" (valid."host/roster" // { timeoutSeconds = 0; });
    timeoutAboveRange = replace "host/roster" (valid."host/roster" // { timeoutSeconds = 601; });
    invalidThresholdOrder = replace "host/restart-counter" (
      restartCounter
      // {
        warningAt = 20;
        failureAt = 5;
      }
    );
    unsafeRequiredPath = replace "host/release-tree" (
      valid."host/release-tree"
      // {
        requiredPaths = {
          "../escape" = {
            kind = "file";
            executable = true;
          };
        };
      }
    );
    freeformCommand = replace "host/numeric-command-threshold" (
      numericThreshold // { command = "printf 1"; }
    );
    arbitraryEnvironment = replace "host/numeric-command-threshold" (
      numericThreshold // { environment.LC_ALL = "C"; }
    );
    arbitraryArgs = replace "host/numeric-command-threshold" (
      numericThreshold // { args = [ "--code=printf 1" ]; }
    );
    commandVersionCodeArgs = replace "host/command-version" (
      valid."host/command-version" // { versionArgs = [ "-c" ]; }
    );
    numericCommandWrongPurpose = replace "host/numeric-command-threshold" (
      numericThreshold // { command = normalizedProtocolCommand; }
    );
    normalizedCommandWrongPurpose = replace "host/normalized-protocol" (
      valid."host/normalized-protocol" // { command = numericCommand; }
    );
    duplicateRequiredResourceKeys = replace "host/normalized-protocol" (
      normalizedProtocol
      // {
        requiredResourceKeys = [
          "summary"
          "summary"
        ];
      }
    );
    duplicateRequiredOutcomeIds = replace "host/normalized-protocol" (
      normalizedProtocol
      // {
        requiredOutcomeIds = [
          "ready"
          "ready"
        ];
      }
    );
    requiredOutcomeOutsideAllowed = replace "host/normalized-protocol" (
      normalizedProtocol
      // {
        requiredOutcomeIds = [ "unknown" ];
      }
    );
    foreignRegistryKey = valid // {
      "foreign" = valid."host/roster";
    };
  };

  invalidCommands = {
    string = "/run/current-system/sw/bin/bash";
    bash = pkgs.bash;
    busybox = pkgs.busybox;
    ksh = pkgs.ksh;
    cmd = cmdExecutable;
    renamed = renamedExecutable;
    text-missing-main-program = markedTextMissingMainProgram;
    text-empty-main-program = markedTextEmptyMainProgram;
    text-unsafe-main-program = markedTextUnsafeMainProgram;
  };
}
