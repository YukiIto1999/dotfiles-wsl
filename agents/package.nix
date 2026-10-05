{
  pkgs,
  lib,
  runtimeContract,
  verificationEntry,
}:

let
  cacheRootRelative = runtimeContract.cache.relativeCacheRoot;
  mkNixBuildShims =
    {
      nixCommand,
      nixBuildCommand,
    }:
    pkgs.symlinkJoin {
      name = "dotfiles-agent-nix-build-shims";
      paths = [
        (pkgs.writeShellApplication {
          name = "nix";
          text = builtins.replaceStrings [ "@nixCommand@" ] [ (toString nixCommand) ] (
            builtins.readFile ./impl/runtime/nix.sh
          );
        })
        (pkgs.writeShellApplication {
          name = "nix-build";
          text = builtins.replaceStrings [ "@nixBuildCommand@" ] [ (toString nixBuildCommand) ] (
            builtins.readFile ./impl/runtime/nix-build.sh
          );
        })
      ];
    };
  mkGitShim =
    { gitCommand }:
    pkgs.writeShellApplication {
      name = "git";
      text = builtins.replaceStrings [ "@gitCommand@" ] [ (lib.escapeShellArg (toString gitCommand)) ] (
        builtins.readFile ./impl/runtime/git.sh
      );
    };
  mkAgentShims =
    {
      nixCommand,
      nixBuildCommand,
      gitCommand,
    }:
    pkgs.symlinkJoin {
      name = "dotfiles-agent-command-shims";
      paths = [
        (mkNixBuildShims { inherit nixCommand nixBuildCommand; })
        (mkGitShim { inherit gitCommand; })
      ];
    };
  agentShims = mkAgentShims {
    nixCommand = lib.getExe pkgs.nix;
    nixBuildCommand = "${pkgs.nix}/bin/nix-build";
    gitCommand = lib.getExe pkgs.git;
  };
  mkLauncher =
    {
      systemdRunCommand ? lib.getExe' pkgs.systemd "systemd-run",
    }:
    pkgs.writeShellApplication {
      name = "dotfiles-agent-runtime";
      runtimeInputs = with pkgs; [
        coreutils
        gawk
        git
        jq
        taplo
        util-linux
      ];
      text =
        builtins.replaceStrings
          [
            "@agentShimDirectory@"
            "@cacheRootRelative@"
            "@systemdRunCommand@"
            "@sliceUnit@"
          ]
          [
            "${agentShims}/bin"
            cacheRootRelative
            (lib.escapeShellArg (toString systemdRunCommand))
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
  gate = pkgs.writeShellApplication {
    name = "dotfiles-agent-gate";
    runtimeInputs = with pkgs; [
      coreutils
      git
      jq
    ];
    text =
      builtins.replaceStrings
        [ "@cacheRootRelative@" "@verificationEntry@" ]
        [ cacheRootRelative (lib.getExe verificationEntry) ]
        (builtins.readFile ./impl/runtime/gate.sh);
  };
  verify = pkgs.writeShellApplication {
    name = "dotfiles-agent-verify";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      git
    ];
    text =
      builtins.replaceStrings
        [ "@cacheRootRelative@" "@gate@" ]
        [ cacheRootRelative "${gate}/bin/dotfiles-agent-gate" ]
        (builtins.readFile ./impl/runtime/verify.sh);
  };
  mkWrapper =
    {
      client,
      binary,
      targetExecutable,
    }:
    pkgs.writeShellApplication {
      name = binary;
      text = ''
        exec ${lib.getExe launcher} ${lib.escapeShellArg client} ${lib.escapeShellArg targetExecutable} "$@"
      '';
    };
in
{
  inherit
    agentShims
    launcher
    mkLauncher
    gate
    gc
    mkAgentShims
    mkNixBuildShims
    mkWrapper
    projectCacheGcSource
    verify
    ;
}
