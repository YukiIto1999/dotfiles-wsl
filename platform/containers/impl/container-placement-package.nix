{
  pkgs,
  lib,
  declaredContainers,
  declaredSlice,
  undeclaredSlice,
  dockerCommand ? lib.getExe pkgs.docker,
  jqCommand ? lib.getExe pkgs.jq,
  systemctlCommand ? "${pkgs.systemd}/bin/systemctl",
}:

let
  name = "dotfiles-observe-container-placement";
  outcomeId = "container-placement";
  contract = {
    envelopeVersion = 1;
    allowedOutcomeIds = [ outcomeId ];
    requiredOutcomeIds = [ outcomeId ];
    requiredResourceKeys = [ ];
  };
  substitutions = {
    "@declaredContainers@" = lib.escapeShellArgs declaredContainers;
    "@declaredSlice@" = lib.escapeShellArg declaredSlice;
    "@dockerCommand@" = lib.escapeShellArg dockerCommand;
    "@envelopeVersion@" = toString contract.envelopeVersion;
    "@jqCommand@" = lib.escapeShellArg jqCommand;
    "@outcomeId@" = lib.escapeShellArg outcomeId;
    "@systemctlCommand@" = lib.escapeShellArg systemctlCommand;
    "@undeclaredSlice@" = lib.escapeShellArg undeclaredSlice;
  };
in
(pkgs.writeShellApplication {
  inherit name;
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./observe-container-placement.sh);
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
