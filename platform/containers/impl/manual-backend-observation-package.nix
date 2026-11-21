{
  pkgs,
  lib,
  application,
  units,
  images,
  healthMethod,
  healthUrl,
  healthTimeout,
  curlCommand ? lib.getExe pkgs.curl,
  dockerCommand ? lib.getExe pkgs.docker,
  jqCommand ? lib.getExe pkgs.jq,
  systemctlCommand ? "${pkgs.systemd}/bin/systemctl",
}:

let
  name = "dotfiles-observe-manual-backend-${application}";
  outcomeId = "container-manual/${application}";
  contract = {
    envelopeVersion = 1;
    allowedOutcomeIds = [ outcomeId ];
    requiredOutcomeIds = [ outcomeId ];
    requiredResourceKeys = [ ];
  };
  substitutions = {
    "@application@" = lib.escapeShellArg application;
    "@units@" = lib.escapeShellArgs units;
    "@containers@" = lib.escapeShellArgs (map (image: image.container) images);
    "@images@" = lib.escapeShellArgs (map (image: image.image) images);
    "@healthMethod@" = lib.escapeShellArg healthMethod;
    "@healthUrl@" = lib.escapeShellArg healthUrl;
    "@healthTimeout@" = toString healthTimeout;
    "@curlCommand@" = lib.escapeShellArg curlCommand;
    "@dockerCommand@" = lib.escapeShellArg dockerCommand;
    "@envelopeVersion@" = toString contract.envelopeVersion;
    "@jqCommand@" = lib.escapeShellArg jqCommand;
    "@systemctlCommand@" = lib.escapeShellArg systemctlCommand;
  };
in
(pkgs.writeShellApplication {
  inherit name;
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./observe-manual-backend.sh);
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
