{
  gatewayUrl,
  lib,
  name ? "dotfiles-mcp-gateway-observer",
  pkgs,
  probes,
  tools ? {
    curl = lib.getExe pkgs.curl;
    jq = lib.getExe pkgs.jq;
    mktemp = "${pkgs.coreutils}/bin/mktemp";
    rm = "${pkgs.coreutils}/bin/rm";
  },
}:

let
  targetIds = builtins.attrNames probes;
  gatewayTimeout = lib.foldl' lib.max 0 (map (id: probes.${id}.timeout) targetIds);
  contract = {
    envelopeVersion = 1;
    allowedOutcomeIds = [
      "mcp-session"
      "mcp-tools"
    ]
    ++ map (id: "mcp-target/${id}") targetIds;
    requiredResourceKeys = [ ];
    inherit gatewayTimeout;
    outerTimeout = 5 * gatewayTimeout;
  };
  substitutions = {
    "@curlCommand@" = lib.escapeShellArg tools.curl;
    "@gatewayTimeout@" = toString contract.gatewayTimeout;
    "@gatewayUrl@" = lib.escapeShellArg gatewayUrl;
    "@jqCommand@" = lib.escapeShellArg tools.jq;
    "@mktempCommand@" = lib.escapeShellArg tools.mktemp;
    "@probesJson@" = lib.escapeShellArg (builtins.toJSON probes);
    "@rmCommand@" = lib.escapeShellArg tools.rm;
  };
  observer = pkgs.writeShellApplication {
    inherit name;
    excludeShellChecks = [ "SC2016" ];
    text =
      builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
        (builtins.readFile ./observer.sh);
  };
in
assert targetIds != [ ];
assert gatewayTimeout >= 1 && contract.outerTimeout <= 600;
observer.overrideAttrs (old: {
  meta = (old.meta or { }) // {
    mainProgram = name;
  };
  passthru = (old.passthru or { }) // {
    dotfilesObservationCommandKind = "normalized-protocol";
    dotfilesObservationContract = contract;
  };
})
