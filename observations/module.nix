{ lib, ... }:

let
  inherit (lib) types;

  nonEmptyString = types.addCheck types.str (value: value != "");
  safeTokenValue =
    value:
    builtins.isString value && value != "" && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" value != null;
  safeToken = types.addCheck nonEmptyString safeTokenValue;
  safeId = types.addCheck nonEmptyString (
    value:
    builtins.all (
      segment:
      segment != ""
      && segment != "."
      && segment != ".."
      && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" segment != null
    ) (lib.splitString "/" value)
  );
  ownerSegment = value: builtins.match "[a-z][a-z0-9]*(-[a-z0-9]+)*" value != null;
  dynamicSegment = value: builtins.match "[a-z0-9][a-z0-9._-]*" value != null;
  registryKey =
    value:
    let
      segments = lib.splitString "/" value;
    in
    builtins.length segments >= 2
    && ownerSegment (lib.head segments)
    && builtins.all dynamicSegment (lib.tail segments);

  pathSegments = value: lib.tail (lib.splitString "/" value);
  normalizedAbsolutePath =
    value:
    value == "/"
    || (
      lib.hasPrefix "/" value
      && !lib.hasSuffix "/" value
      && builtins.all (segment: segment != "" && segment != "." && segment != "..") (pathSegments value)
    );
  absolutePath = types.addCheck nonEmptyString normalizedAbsolutePath;
  purposeCommandPackage =
    kind:
    let
      packageType = types.addCheck types.package (
        package:
        (package.dotfilesObservationCommandKind or null) == kind
        && safeTokenValue (package.meta.mainProgram or null)
      );
    in
    packageType
    // {
      description = "${kind}専用markerと安全なmeta.mainProgramを持つpackage";
    };
  safeRelativePath =
    value:
    value != ""
    && !lib.hasPrefix "/" value
    && !lib.hasSuffix "/" value
    && builtins.all (segment: segment != "" && segment != "." && segment != "..") (
      lib.splitString "/" value
    );
  relativePath = types.addCheck nonEmptyString safeRelativePath;
  relativeSymlinkTarget = types.addCheck nonEmptyString (
    value: lib.hasPrefix "../" value && safeRelativePath (lib.removePrefix "../" value)
  );
  httpUrl = types.addCheck nonEmptyString (
    value: builtins.match "https?://[^[:space:][:cntrl:]]+" value != null
  );

  uniqueNonEmptyListOf =
    elementType:
    types.addCheck (types.nonEmptyListOf elementType) (values: values == lib.unique values);
  timeoutSeconds = types.ints.between 1 600;
  percent = types.ints.between 0 100;
  versionArgsType = types.enum [ [ "--version" ] ];

  commonOptions = {
    checkId = lib.mkOption {
      type = types.nullOr safeId;
      default = null;
    };
    resourceKey = lib.mkOption {
      type = types.nullOr safeToken;
      default = null;
    };
    timeoutSeconds = lib.mkOption { type = timeoutSeconds; };
    failureMessage = lib.mkOption { type = nonEmptyString; };
  };

  requiredPathType = types.submodule {
    options = {
      kind = lib.mkOption {
        type = types.enum [
          "file"
          "directory"
        ];
      };
      executable = lib.mkOption { type = types.bool; };
    };
  };
  requiredPathsType = types.attrsOf requiredPathType;

  loadState = types.enum [
    "loaded"
    "error"
    "not-found"
    "bad-setting"
    "masked"
  ];
  activeState = types.enum [
    "active"
    "reloading"
    "inactive"
    "failed"
    "activating"
    "deactivating"
    "maintenance"
    "refreshing"
  ];
  serviceResult = types.enum [
    "success"
    "exit-code"
    "signal"
    "core-dump"
    "watchdog"
    "start-limit-hit"
    "resources"
    "timeout"
    "protocol"
    "dependency"
    "skipped"
    "oom-kill"
  ];
  unitFileState = types.enum [
    "enabled"
    "enabled-runtime"
    "linked"
    "linked-runtime"
    "alias"
    "masked"
    "masked-runtime"
    "static"
    "disabled"
    "indirect"
    "generated"
    "transient"
    "bad"
  ];
  serviceUnit = types.addCheck safeToken (lib.hasSuffix ".service");
  timerUnit = types.addCheck safeToken (lib.hasSuffix ".timer");

  thresholdOrderIsValid =
    observation:
    builtins.isInt (observation.warning or null)
    && builtins.isInt (observation.failure or null)
    && (
      if (observation.metric or null) == "free-percent" then
        observation.failure < observation.warning
      else
        observation.warning < observation.failure
    );

  mkObservationType =
    kind: specificOptions: check:
    types.addCheck (types.submodule {
      options =
        commonOptions
        // specificOptions
        // {
          kind = lib.mkOption { type = types.enum [ kind ]; };
        };
    }) (observation: (observation.kind or null) == kind && check observation);

  rosterType =
    mkObservationType "roster"
      {
        members = lib.mkOption { type = uniqueNonEmptyListOf safeId; };
        minimumCount = lib.mkOption { type = types.ints.positive; };
        failureOnly = lib.mkOption { type = types.bool; };
      }
      (
        observation:
        builtins.isList (observation.members or null)
        && builtins.isInt (observation.minimumCount or null)
        && observation.minimumCount <= builtins.length observation.members
      );

  pathMatchType = mkObservationType "path-match" {
    currentPath = lib.mkOption { type = absolutePath; };
    requiredPath = lib.mkOption { type = absolutePath; };
    resolution = lib.mkOption {
      type = types.enum [
        "literal"
        "canonical"
      ];
    };
  } (_: true);

  commandVersionType = mkObservationType "command-version" {
    path = lib.mkOption { type = absolutePath; };
    versionArgs = lib.mkOption { type = versionArgsType; };
    expectedSource = lib.mkOption { type = absolutePath; };
  } (_: true);

  releaseTreeType =
    mkObservationType "release-tree"
      {
        visiblePath = lib.mkOption { type = absolutePath; };
        visibleTarget = lib.mkOption { type = relativeSymlinkTarget; };
        currentLink = lib.mkOption { type = absolutePath; };
        releasesRoot = lib.mkOption { type = absolutePath; };
        entrypoint = lib.mkOption { type = relativePath; };
        requiredPaths = lib.mkOption { type = requiredPathsType; };
        versionArgs = lib.mkOption { type = versionArgsType; };
      }
      (
        observation:
        builtins.isAttrs (observation.requiredPaths or null)
        && builtins.all safeRelativePath (builtins.attrNames observation.requiredPaths)
      );

  deployedPathType = mkObservationType "deployed-path" {
    source = lib.mkOption { type = absolutePath; };
    destination = lib.mkOption { type = absolutePath; };
    acceptedDestinationKinds = lib.mkOption {
      type = uniqueNonEmptyListOf (
        types.enum [
          "regular-file"
          "symlink"
        ]
      );
    };
  } (_: true);

  pathMetadataType = mkObservationType "path-metadata" {
    path = lib.mkOption { type = absolutePath; };
    owner = lib.mkOption { type = safeToken; };
    group = lib.mkOption { type = safeToken; };
    mode = lib.mkOption {
      type = types.addCheck types.str (value: builtins.match "[0-7]{4}" value != null);
    };
  } (_: true);

  managedRootsType = mkObservationType "managed-roots" {
    paths = lib.mkOption { type = uniqueNonEmptyListOf absolutePath; };
    missingAsZero = lib.mkOption { type = types.bool; };
    oneFileSystem = lib.mkOption { type = types.bool; };
    cachePolicy = lib.mkOption { type = types.enum [ "allocated-bytes" ]; };
  } (_: true);

  systemdServiceType = mkObservationType "systemd-service" {
    unit = lib.mkOption { type = serviceUnit; };
    loadStates = lib.mkOption { type = uniqueNonEmptyListOf loadState; };
    activeStates = lib.mkOption { type = uniqueNonEmptyListOf activeState; };
    results = lib.mkOption { type = uniqueNonEmptyListOf serviceResult; };
  } (_: true);

  systemdTimerType = mkObservationType "systemd-timer" {
    timer = lib.mkOption { type = timerUnit; };
    service = lib.mkOption { type = serviceUnit; };
    unitFileStates = lib.mkOption { type = uniqueNonEmptyListOf unitFileState; };
    activeStates = lib.mkOption { type = uniqueNonEmptyListOf activeState; };
    serviceResults = lib.mkOption { type = uniqueNonEmptyListOf serviceResult; };
  } (_: true);

  restartCounterType =
    mkObservationType "restart-counter"
      {
        sourceKind = lib.mkOption {
          type = types.enum [
            "systemd-service"
            "container"
          ];
        };
        target = lib.mkOption { type = safeToken; };
        warningAt = lib.mkOption { type = types.ints.unsigned; };
        failureAt = lib.mkOption { type = types.ints.positive; };
      }
      (
        observation:
        builtins.isInt (observation.warningAt or null)
        && builtins.isInt (observation.failureAt or null)
        && observation.warningAt < observation.failureAt
      );

  filesystemThresholdType = mkObservationType "filesystem-threshold" {
    path = lib.mkOption { type = absolutePath; };
    metric = lib.mkOption {
      type = types.enum [
        "used-percent"
        "free-percent"
      ];
    };
    warning = lib.mkOption { type = percent; };
    failure = lib.mkOption { type = percent; };
  } thresholdOrderIsValid;

  numericCommandThresholdType = mkObservationType "numeric-command-threshold" {
    command = lib.mkOption { type = purposeCommandPackage "numeric-command-threshold"; };
    metric = lib.mkOption {
      type = types.enum [
        "used-percent"
        "free-percent"
      ];
    };
    warning = lib.mkOption { type = percent; };
    failure = lib.mkOption { type = percent; };
  } thresholdOrderIsValid;

  swapPolicyType = mkObservationType "swap-policy" {
    minimumTotalBytes = lib.mkOption { type = types.ints.positive; };
    requiredZramAlgorithm = lib.mkOption {
      type = types.enum [
        "lzo"
        "lzo-rle"
        "zstd"
        "lz4"
        "lz4hc"
        "deflate"
        "842"
      ];
    };
    requireZram = lib.mkOption { type = types.bool; };
    zramAboveDisk = lib.mkOption { type = types.bool; };
  } (_: true);

  journalSizeType = mkObservationType "journal-size" {
    maximumBytes = lib.mkOption { type = types.ints.positive; };
  } (_: true);

  containerImageType = mkObservationType "container-image" {
    container = lib.mkOption { type = safeToken; };
    image = lib.mkOption {
      type = types.addCheck nonEmptyString (value: builtins.match "[^[:space:][:cntrl:]]+" value != null);
    };
  } (_: true);

  httpHealthType = mkObservationType "http-health" {
    method = lib.mkOption {
      type = types.enum [
        "GET"
        "POST"
      ];
    };
    url = lib.mkOption { type = httpUrl; };
  } (_: true);

  normalizedProtocolType = mkObservationType "normalized-protocol" {
    command = lib.mkOption { type = purposeCommandPackage "normalized-protocol"; };
    allowedOutcomeIds = lib.mkOption { type = uniqueNonEmptyListOf safeId; };
    requiredResourceKeys = lib.mkOption { type = uniqueNonEmptyListOf safeToken; };
    envelopeVersion = lib.mkOption { type = types.ints.positive; };
  } (_: true);

  observationType = types.oneOf [
    rosterType
    pathMatchType
    commandVersionType
    releaseTreeType
    deployedPathType
    pathMetadataType
    managedRootsType
    systemdServiceType
    systemdTimerType
    restartCounterType
    filesystemThresholdType
    numericCommandThresholdType
    swapPolicyType
    journalSizeType
    containerImageType
    httpHealthType
    normalizedProtocolType
  ];
in
{
  options.dotfiles.observations = lib.mkOption {
    type = types.addCheck (types.attrsOf observationType) (
      registry: builtins.all registryKey (builtins.attrNames registry)
    );
    default = { };
    internal = true;
    description = "各ownerが登録し、doctorが消費する型付きruntime observation。";
  };
}
