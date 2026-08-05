{
  pkgs,
  lib,
  tools ? {
    curl = lib.getExe pkgs.curl;
    docker = lib.getExe pkgs.docker;
    jq = lib.getExe pkgs.jq;
    cmp = "${pkgs.coreutils}/bin/cmp";
    readlink = "${pkgs.coreutils}/bin/readlink";
    stat = "${pkgs.coreutils}/bin/stat";
    systemctl = "${pkgs.systemd}/bin/systemctl";
  },
  tables,
}:

let
  substitutions = {
    "@agentTable@" = lib.escapeShellArg (builtins.toJSON tables.agentTable);
    "@artifactTable@" = lib.escapeShellArg (builtins.toJSON tables.artifactTable);
    "@secretTable@" = lib.escapeShellArg (builtins.toJSON tables.secretTable);
    "@serviceTable@" = lib.escapeShellArg (builtins.toJSON tables.serviceTable);
    "@containerTable@" = lib.escapeShellArg (builtins.toJSON tables.containerTable);
    "@healthTable@" = lib.escapeShellArg (builtins.toJSON tables.healthTable);
    "@mcpTable@" = lib.escapeShellArg (builtins.toJSON tables.mcpTable);
    "@gatewayUrl@" = lib.escapeShellArg (builtins.toJSON tables.gatewayUrl);
    "@curlCommand@" = lib.escapeShellArg tools.curl;
    "@dockerCommand@" = lib.escapeShellArg tools.docker;
    "@jqCommand@" = lib.escapeShellArg tools.jq;
    "@cmpCommand@" = lib.escapeShellArg tools.cmp;
    "@readlinkCommand@" = lib.escapeShellArg tools.readlink;
    "@statCommand@" = lib.escapeShellArg tools.stat;
    "@systemctlCommand@" = lib.escapeShellArg tools.systemctl;
  };
in
(pkgs.writeShellApplication {
  name = "dotfiles-doctor";
  excludeShellChecks = [ "SC2016" ];
  runtimeInputs = with pkgs; [
    coreutils
    curl
    docker
    jq
    systemd
  ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./impl/doctor.sh);
}).overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit tables;
    };
  })
