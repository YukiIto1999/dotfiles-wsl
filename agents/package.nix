{
  pkgs,
  lib,
  ledgerRetentionDays ? 30,
}:

let
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
    {
      gitCommand,
      worktreeCommand,
    }:
    let
      worktreeDispatcher = pkgs.writeShellApplication {
        name = "dotfiles-agent-worktree-dispatch";
        text = ''
          if [ -n "''${GIT_PREFIX-}" ]; then
            cd -- "$GIT_PREFIX"
          fi
          exec ${lib.escapeShellArg (toString worktreeCommand)} "$@"
        '';
      };
      gitShim = pkgs.writeShellApplication {
        name = "git";
        text =
          builtins.replaceStrings
            [
              "@gitCommand@"
              "@worktreeAlias@"
            ]
            [
              (lib.escapeShellArg (toString gitCommand))
              (lib.escapeShellArg "!${lib.getExe worktreeDispatcher}")
            ]
            (builtins.readFile ./impl/runtime/git.sh);
      };
    in
    pkgs.symlinkJoin {
      name = "dotfiles-agent-git-shim";
      paths = [
        gitShim
        worktreeDispatcher
      ];
    };
  mkAgentShims =
    {
      nixCommand,
      nixBuildCommand,
      gitCommand,
      worktreeCommand,
    }:
    pkgs.symlinkJoin {
      name = "dotfiles-agent-command-shims";
      paths = [
        (mkNixBuildShims { inherit nixCommand nixBuildCommand; })
        (mkGitShim { inherit gitCommand worktreeCommand; })
      ];
    };
  mkAgentResource =
    {
      gitCommand,
      retentionDays ? ledgerRetentionDays,
      name ? "dotfiles-agent-resource",
    }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        coreutils
        gawk
        git
        jq
        util-linux
      ];
      text =
        builtins.replaceStrings
          [
            "@gitCommand@"
            "@ledgerRetentionDays@"
          ]
          [
            (lib.escapeShellArg (toString gitCommand))
            (toString retentionDays)
          ]
          (builtins.readFile ./impl/resource/agent-resource.sh);
    };
  mkAgentWorktree =
    {
      gitCommand,
      resourceCommand,
      name ? "dotfiles-agent-worktree",
    }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        coreutils
        git
        gnugrep
        util-linux
      ];
      text =
        builtins.replaceStrings
          [
            "@gitCommand@"
            "@resourceCommand@"
          ]
          [
            (lib.escapeShellArg (toString gitCommand))
            (lib.escapeShellArg (toString resourceCommand))
          ]
          (builtins.readFile ./impl/resource/agent-worktree.sh);
    };
  agentResource = mkAgentResource { gitCommand = lib.getExe pkgs.git; };
  agentWorktree = mkAgentWorktree {
    gitCommand = lib.getExe pkgs.git;
    resourceCommand = lib.getExe agentResource;
  };
  nixBuildShims = mkNixBuildShims {
    nixCommand = lib.getExe pkgs.nix;
    nixBuildCommand = "${pkgs.nix}/bin/nix-build";
  };
  agentShims = mkAgentShims {
    nixCommand = lib.getExe pkgs.nix;
    nixBuildCommand = "${pkgs.nix}/bin/nix-build";
    gitCommand = lib.getExe pkgs.git;
    worktreeCommand = lib.getExe agentWorktree;
  };
  launcher = pkgs.writeShellApplication {
    name = "dotfiles-agent-runtime";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      git
      jq
      taplo
      util-linux
    ];
    text = builtins.replaceStrings [ "@agentShimDirectory@" ] [ "${agentShims}/bin" ] (
      builtins.readFile ./impl/runtime/launcher.sh
    );
  };
  gc = pkgs.writeShellApplication {
    name = "dotfiles-agent-project-cache-gc";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      jq
      util-linux
    ];
    text = builtins.readFile ./impl/runtime/project-cache-gc.sh;
  };
  verify = pkgs.writeShellApplication {
    name = "dotfiles-agent-verify";
    runtimeInputs = with pkgs; [
      coreutils
      git
    ];
    text = builtins.readFile ./impl/runtime/verify.sh;
  };
  mkWrapper =
    {
      client,
      binary,
      homeDir,
    }:
    pkgs.writeShellApplication {
      name = binary;
      text = ''
        exec ${lib.getExe launcher} ${lib.escapeShellArg client} ${lib.escapeShellArg "${homeDir}/.local/bin/${binary}"} "$@"
      '';
    };
in
{
  inherit
    agentResource
    agentShims
    agentWorktree
    launcher
    gc
    mkAgentShims
    mkAgentResource
    mkAgentWorktree
    mkGitShim
    mkNixBuildShims
    mkWrapper
    nixBuildShims
    verify
    ;
}
