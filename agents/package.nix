{
  pkgs,
  lib,
  runtimeContract,
  verificationEntry,
  executionPolicy,
  supervise,
  # sandbox には user manager も Nix daemon も無いため、検査は同じ実装へ記録と代替の command を渡す。
  systemdRunCommand ? lib.getExe' pkgs.systemd "systemd-run",
  systemctlCommand ? lib.getExe' pkgs.systemd "systemctl",
  nixStoreCommand ? "${lib.getBin pkgs.nix}/bin/nix-store",
}:

let
  cacheRootRelative = runtimeContract.cache.relativeCacheRoot;
  defaultNixStoreCommand = nixStoreCommand;
  mkGitShim =
    { gitCommand }:
    pkgs.writeShellApplication {
      name = "git";
      text = builtins.replaceStrings [ "@gitCommand@" ] [ (lib.escapeShellArg (toString gitCommand)) ] (
        builtins.readFile ./impl/runtime/git.sh
      );
    };
  gitShim = mkGitShim { gitCommand = lib.getExe pkgs.git; };
  mkProtect =
    {
      nixStoreCommand ? defaultNixStoreCommand,
    }:
    pkgs.writeShellApplication {
      name = "dotfiles-agent-protect";
      runtimeInputs = [ pkgs.coreutils ];
      text =
        builtins.replaceStrings [ "@nixStoreCommand@" ] [ (lib.escapeShellArg (toString nixStoreCommand)) ]
          (builtins.readFile ./impl/runtime/protect.sh);
    };
  protect = mkProtect { };
  mkLauncher =
    {
      protectCommand ? protect,
      commandShims ? null,
    }:
    pkgs.writeShellApplication {
      name = "dotfiles-agent-runtime";
      runtimeInputs =
        lib.optional (commandShims != null) commandShims
        ++ (with pkgs; [
          coreutils
          gawk
          git
          jq
          util-linux
        ]);
      text =
        builtins.replaceStrings
          [
            "@gitShimDirectory@"
            "@cacheRootRelative@"
            "@systemdRunCommand@"
            "@systemctlCommand@"
            "@protectCommand@"
            "@superviseCommand@"
            "@sliceUnit@"
          ]
          [
            "${gitShim}/bin"
            cacheRootRelative
            (lib.escapeShellArg (toString systemdRunCommand))
            (lib.escapeShellArg (toString systemctlCommand))
            (lib.escapeShellArg (lib.getExe protectCommand))
            (lib.escapeShellArg (lib.getExe supervise))
            runtimeContract.sliceUnit
          ]
          (builtins.readFile ./impl/runtime/launcher.sh);
    };
  launcher = mkLauncher { };
  projectCacheGcSource =
    builtins.replaceStrings
      [
        "@cacheRootRelative@"
        "@gcHighBytes@"
        "@gcLowBytes@"
        "@gcInactiveDays@"
        "@sliceUnit@"
      ]
      [
        cacheRootRelative
        (toString runtimeContract.cache.highBytes)
        (toString runtimeContract.cache.lowBytes)
        (toString runtimeContract.cache.inactiveDays)
        runtimeContract.sliceUnit
      ]
      (builtins.readFile ./impl/runtime/project-cache-gc.sh);
  gc = pkgs.writeShellApplication {
    name = "dotfiles-agent-project-cache-gc";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      jq
      util-linux
    ];
    text = projectCacheGcSource;
  };
  mkGate =
    {
      commandShims ? null,
    }:
    pkgs.writeShellApplication {
      name = "dotfiles-agent-gate";
      runtimeInputs =
        lib.optional (commandShims != null) commandShims
        ++ (with pkgs; [
          coreutils
          git
          jq
          nodejs
        ]);
      text =
        builtins.replaceStrings
          [
            "@cacheRootRelative@"
            "@verificationEntry@"
            "@skillRoots@"
            "@standardRoot@"
          ]
          [
            cacheRootRelative
            (lib.getExe verificationEntry)
            (lib.escapeShellArgs runtimeContract.skillRoots)
            (lib.escapeShellArg runtimeContract.standardRoot)
          ]
          (builtins.readFile ./impl/runtime/gate.sh);
    };
  gate = mkGate { };
  mkVerificationCache =
    {
      gateCommand,
      commandShims ? null,
    }:
    pkgs.writeShellApplication {
      name = "dotfiles-agent-verification-cache";
      runtimeInputs =
        lib.optional (commandShims != null) commandShims
        ++ (with pkgs; [
          coreutils
          diffutils
          git
        ]);
      text =
        builtins.replaceStrings
          [ "@cacheRootRelative@" "@gate@" ]
          [ cacheRootRelative (lib.getExe gateCommand) ]
          (builtins.readFile ./impl/runtime/verify-cache.sh);
    };
  mkVerify =
    {
      commandShims ? null,
    }:
    let
      verifyGate = mkGate { inherit commandShims; };
      verifyCache = mkVerificationCache {
        gateCommand = verifyGate;
        inherit commandShims;
      };
    in
    pkgs.writeShellApplication {
      name = "dotfiles-agent-verify";
      runtimeInputs = with pkgs; [
        coreutils
        git
      ];
      text =
        builtins.replaceStrings
          [ "@gate@" "@verificationCache@" ]
          [
            (lib.escapeShellArg (lib.getExe verifyGate))
            (lib.escapeShellArg (lib.getExe verifyCache))
          ]
          (builtins.readFile ./impl/runtime/verify.sh);
    };
  verify = mkVerify { };
  mkWrapper =
    {
      client,
      binary,
      targetExecutable,
      executionDependencies,
    }:
    let
      dependencies = lib.unique (map toString executionDependencies);
      outsideStore = builtins.filter (path: !(lib.hasPrefix "${builtins.storeDir}/" path)) dependencies;
    in
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9._][A-Za-z0-9._-]*" client != null
    ) "runtime wrapper client id is invalid: ${client}";
    assert lib.assertMsg (
      builtins.match "/[^[:space:]]+" targetExecutable != null
    ) "runtime wrapper target is not an absolute path: ${targetExecutable}";
    assert lib.assertMsg (
      outsideStore == [ ]
    ) "runtime wrapper execution dependencies must be store paths: ${toString outsideStore}";
    # wrapper 自身と execution dependency を、起動時に確定した実行依存として launcher へ渡す。
    # 共通の cache 方針は一度だけここで適用し、lifecycle へはその後に渡す。
    pkgs.writeShellApplication {
      name = binary;
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        exec ${lib.getExe executionPolicy} \
          --shared-cache "$HOME/${cacheRootRelative}/shared" \
          --build-root "$HOME/${cacheRootRelative}/cargo-build" \
          -- ${lib.getExe launcher} --protect "$(realpath -e -- "$0")" \
          ${lib.concatMapStrings (path: "--protect ${lib.escapeShellArg path} ") dependencies}\
          ${lib.escapeShellArg client} ${lib.escapeShellArg targetExecutable} "$@"
      '';
    };
in
{
  inherit
    gate
    gc
    gitShim
    launcher
    mkGitShim
    mkLauncher
    mkProtect
    mkVerify
    mkWrapper
    projectCacheGcSource
    protect
    supervise
    verify
    ;
}
