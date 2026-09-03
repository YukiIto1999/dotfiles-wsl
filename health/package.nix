{
  pkgs,
  lib,
  observations,
  probeOverride ? null,
  tools ? {
    cmp = "${pkgs.diffutils}/bin/cmp";
    curl = lib.getExe pkgs.curl;
    df = "${pkgs.coreutils}/bin/df";
    docker = lib.getExe pkgs.docker;
    du = "${pkgs.coreutils}/bin/du";
    env = "${pkgs.coreutils}/bin/env";
    head = "${pkgs.coreutils}/bin/head";
    journalctl = "${pkgs.systemd}/bin/journalctl";
    jq = lib.getExe pkgs.jq;
    mktemp = "${pkgs.coreutils}/bin/mktemp";
    readlink = "${pkgs.coreutils}/bin/readlink";
    rm = "${pkgs.coreutils}/bin/rm";
    stat = "${pkgs.coreutils}/bin/stat";
    swapon = "${pkgs.util-linux}/bin/swapon";
    systemctl = "${pkgs.systemd}/bin/systemctl";
    timeout = "${pkgs.coreutils}/bin/timeout";
    wc = "${pkgs.coreutils}/bin/wc";
    zramctl = "${pkgs.util-linux}/bin/zramctl";
  },
}:

let
  probeSubstitutions = {
    "@cmpCommand@" = lib.escapeShellArg tools.cmp;
    "@curlCommand@" = lib.escapeShellArg tools.curl;
    "@dfCommand@" = lib.escapeShellArg tools.df;
    "@dockerCommand@" = lib.escapeShellArg tools.docker;
    "@duCommand@" = lib.escapeShellArg tools.du;
    "@headCommand@" = lib.escapeShellArg tools.head;
    "@journalctlCommand@" = lib.escapeShellArg tools.journalctl;
    "@jqCommand@" = lib.escapeShellArg tools.jq;
    "@readlinkCommand@" = lib.escapeShellArg tools.readlink;
    "@statCommand@" = lib.escapeShellArg tools.stat;
    "@swaponCommand@" = lib.escapeShellArg tools.swapon;
    "@systemctlCommand@" = lib.escapeShellArg tools.systemctl;
    "@wcCommand@" = lib.escapeShellArg tools.wc;
    "@zramctlCommand@" = lib.escapeShellArg tools.zramctl;
  };
  generatedProbe = pkgs.writeShellApplication {
    name = "dotfiles-doctor-probe";
    excludeShellChecks = [ "SC2016" ];
    runtimeInputs = [ pkgs.jq ];
    text =
      builtins.replaceStrings (builtins.attrNames probeSubstitutions)
        (builtins.attrValues probeSubstitutions)
        (builtins.readFile ./impl/probe.sh);
  };
  probe = if probeOverride == null then generatedProbe else probeOverride;
  doctorSubstitutions = {
    "@envCommand@" = lib.escapeShellArg tools.env;
    "@headCommand@" = lib.escapeShellArg tools.head;
    "@jqCommand@" = lib.escapeShellArg tools.jq;
    "@mktempCommand@" = lib.escapeShellArg tools.mktemp;
    "@observations@" = lib.escapeShellArg (builtins.toJSON observations);
    "@probeCommand@" = lib.escapeShellArg (lib.getExe probe);
    "@rmCommand@" = lib.escapeShellArg tools.rm;
    "@runtimePath@" = lib.escapeShellArg (lib.makeBinPath [ pkgs.coreutils ]);
    "@timeoutCommand@" = lib.escapeShellArg tools.timeout;
    "@wcCommand@" = lib.escapeShellArg tools.wc;
  };
in
(pkgs.writeShellApplication {
  name = "dotfiles-doctor";
  excludeShellChecks = [
    "SC2016"
    "SC2329"
  ];
  runtimeInputs = [ pkgs.jq ];
  text =
    builtins.replaceStrings (builtins.attrNames doctorSubstitutions)
      (builtins.attrValues doctorSubstitutions)
      (builtins.readFile ./impl/doctor.sh);
}).overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit observations probe;
    };
  })
