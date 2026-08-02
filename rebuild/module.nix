{
  config,
  lib,
  pkgs,
  mkCommand,
  ...
}:

let
  nixosRebuildGuardVars = {
    nixosRebuild = lib.escapeShellArg (lib.getExe config.system.build.nixos-rebuild);
    nixosRebuildPath = lib.getExe config.system.build.nixos-rebuild;
  };

  # rebuild の shell が展開する値。command 固有なのでこの unit が所有する
  rebuildVars = nixosRebuildGuardVars // {
    # doctor が所有する schema を読む。rebuild 側に数値を転記しない
    doctorSchemaVersion = toString config.my.contract.doctor.schemaVersion;
    legacyDoctorSchemaVersion = "2";
    bootIdFile = "/proc/sys/kernel/random/boot_id";
    nixGcAutoRootDir = "/nix/var/nix/gcroots/auto";
    awk = lib.escapeShellArg (lib.getExe pkgs.gawk);
    activationLogLimitBytes = toString (8 * 1024 * 1024);
    legacySchema2RebuildSourceSha256 = "6981dc736aa6c38070e448b8568aa96ea67802611675129cea60ef5bfbe0c710";
    legacySchema2CandidateHelperSha256 = "6a88d31acbc01b0da1c474757bcfd02dfd58a0fc95230a1fb1ef168af57a6ae5";
    legacySchema2NixpkgsRev = "bd0ff2d3eac24699c3664d5966b9ef36f388e2ca";
    legacySchema2NixosRebuildPath = "/nix/store/gi6qsdlby13jf9szb23blh8rmywvi81i-nixos-rebuild-ng-26.05/bin/nixos-rebuild";
    atomicFileFunctions = builtins.readFile ./impl/lib/atomic-file.sh;
    operationLockFunctions = builtins.readFile ./impl/lib/operation-lock.sh;
    rebuildAttemptFunctions = builtins.readFile ./impl/lib/rebuild-attempt.sh;
    rebuildReceiptFunctions = builtins.readFile ./impl/lib/rebuild-receipt.sh;
  };

  wslRestartRequired = mkCommand {
    name = "dotfiles-wsl-restart-required";
    src = ./impl/wsl-restart-required.sh;
    runtimeInputs = with pkgs; [ coreutils ];
    vars = rebuildVars;
  };

  rebuild = mkCommand {
    name = "dotfiles-rebuild";
    src = ./impl/rebuild.sh;
    runtimeInputs =
      (with pkgs; [
        git
        gawk
        coreutils
        jq
        nix
        nix-output-monitor
        nvd
        systemd
        util-linux
      ])
      ++ [ wslRestartRequired ];
    vars = rebuildVars;
    # jq programs are single-quoted; their $names come from --arg/--argjson.
    extra.excludeShellChecks = [ "SC2016" ];
  };

  # PATH 上の直接呼び出しを拒否する。上流実体は transaction 内から store path で呼ぶ
  nixosRebuildGuard = pkgs.writeShellApplication {
    name = "nixos-rebuild";
    text = ''
      echo "FATAL: direct nixos-rebuild bypasses the dotfiles rebuild transaction" >&2
      echo "Use dotfiles-rebuild for normal changes; use bootstrap/impl/bootstrap.sh only for initial provisioning." >&2
      exit 2
    '';
  };
in
{
  my.commands = {
    inherit rebuild wslRestartRequired;
  };

  # 他 unit の script が取り込む shell library。impl を path で直読みさせない
  my.contract.rebuild.libraries = {
    atomicFile = ./impl/lib/atomic-file.sh;
    operationLock = ./impl/lib/operation-lock.sh;
    rebuildAttempt = ./impl/lib/rebuild-attempt.sh;
    rebuildReceipt = ./impl/lib/rebuild-receipt.sh;
  };

  system.tools.nixos-rebuild.enable = false;
  environment.systemPackages = [ nixosRebuildGuard ];
}
