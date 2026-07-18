{
  config,
  lib,
  pkgs,
  ...
}:

# writeShellApplication は shellcheck を build に含むため、規約逸脱は nix build 時点で落ちる
let
  cfg = config.my;
  inherit (cfg) clis;
  names = builtins.attrNames clis;

  orElse = v: default: if v == null then default else v;

  # roster を「1 行 1 CLI」の pipe 区切りテーブルへ変換、doctor / install-clis はこれを読むだけ
  cliRow =
    name:
    let
      c = clis.${name};
    in
    lib.concatStringsSep "|" [
      name
      c.binary
      c.rulesFile
      c.skillsDir
      (orElse c.agentsDir "")
      (orElse c.gatewayFile "")
    ];

  installRow =
    name:
    let
      c = clis.${name};
    in
    if c.install.kind == "installer-script" then
      lib.concatStringsSep "|" [
        name
        c.install.kind
        c.binary
        c.install.scriptUrl
        ""
        ""
        ""
      ]
    else
      lib.concatStringsSep "|" [
        name
        c.install.kind
        c.binary
        c.install.repo
        c.install.assetByArch.x86_64
        c.install.assetByArch.aarch64
        (orElse (c.install.binaryInArchive or null) "")
      ];

  # cleanup が hm-back を掃く root、.config/<x> は 2 段まで、それ以外は先頭 1 段
  cliRootOf =
    path:
    let
      segs = lib.splitString "/" path;
    in
    if builtins.head segs == ".config" then
      lib.concatStringsSep "/" (lib.sublist 0 2 segs)
    else
      builtins.head segs;

  cliRoots = lib.unique (map (name: cliRootOf clis.${name}.rulesFile) names) ++ [
    ".config/git"
    ".config/gh"
  ];

  substitute =
    vars: text:
    builtins.replaceStrings (map (k: "@${k}@") (
      builtins.attrNames vars
    )) (builtins.attrValues vars) text;

  commonVars = {
    inherit (cfg) dotfilesDir;
    inherit (cfg) gatewayUrl;
    inherit (cfg) username;
    cliTable = lib.concatStringsSep "\n" (map cliRow names);
    installTable = lib.concatStringsSep "\n" (map installRow names);
    mcpTargetNames = lib.concatStringsSep " " (builtins.attrNames cfg.mcp.targets);
    gatewayWaitUnits = lib.concatStringsSep " " cfg.mcp.gatewayWaitUnits;
    cliRootsBashArray = lib.concatStringsSep " " (map (r: "'${r}'") cliRoots);
    hmBackupExt = config.home-manager.backupFileExtension;
  };

  mkCommand =
    name: srcFile: runtimeInputs: extra:
    pkgs.writeShellApplication (
      {
        inherit name runtimeInputs;
        text = substitute commonVars (builtins.readFile srcFile);
      }
      // extra
    );

  # ok/bad の A && B || C は本 repo の一貫した idiom、元 scripts/*.sh も同型で SC2015/16 は許容
  doctorChecks = {
    excludeShellChecks = [
      "SC2015"
      "SC2016"
    ];
  };

  doctor = mkCommand "dotfiles-doctor" ./commands/doctor (with pkgs; [
    curl
    jq
    gnugrep
    gawk
    coreutils
    findutils
    systemd
  ]) doctorChecks;
  rebuild = mkCommand "dotfiles-rebuild" ./commands/rebuild (with pkgs; [
    git
    coreutils
  ]) { };
  wslRestartRequired = mkCommand "dotfiles-wsl-restart-required" ./commands/wsl-restart-required (
    with pkgs; [ coreutils ]) { };
  installClis = mkCommand "dotfiles-install-clis" ./commands/install-clis (with pkgs; [
    bash
    curl
    jq
    gnutar
    gzip
    coreutils
  ]) { };
  cleanup = mkCommand "dotfiles-cleanup" ./commands/cleanup (with pkgs; [ coreutils ]) { };
in
{
  options.my.commands = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    internal = true;
    description = "config から生成する運用コマンド。flake.nix の packages 出力が nixosConfiguration 経由でここを参照する。";
  };

  config.my.commands = {
    inherit
      doctor
      rebuild
      wslRestartRequired
      cleanup
      installClis
      ;
  };

  config.environment.systemPackages = builtins.attrValues cfg.commands;

  config.systemd.services.dotfiles-cli-autoupdate = {
    description = "AI CLI を latest へ更新";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = cfg.username;
      Environment = [
        "HOME=${cfg.homeDir}"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
      ];
      ExecStart = lib.getExe installClis;
    };
  };

  config.systemd.timers.dotfiles-cli-autoupdate = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
