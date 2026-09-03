{
  lib,
  pkgs,
  self,
  ...
}:

let
  fixtureExecutable = "/fixture/client executables/codex's";
  expectedCommand = "${lib.escapeShellArg fixtureExecutable} mcp-server";
  fixtureFront =
    pkgs.runCommandLocal "fixture-codex-mcp-front"
      {
        meta.mainProgram = "codex-mcp";
      }
      ''
        mkdir -p "$out/bin"
        touch "$out/bin/codex-mcp"
      '';
  fixturePkgs = pkgs // {
    callPackage =
      path: args:
      if path == ../../../../platform/mcp/package/mk-server.nix then
        spec:
        assert
          spec == {
            name = "codex-mcp";
            command = expectedCommand;
          };
        fixtureFront
      else
        pkgs.callPackage path args;
  };
  evaluation = lib.evalModules {
    specialArgs.pkgs = fixturePkgs;
    modules = [
      ./module.nix
      (
        { lib, ... }:
        {
          options.dotfiles = {
            capabilities.agent-session.codex.runtime.executable = lib.mkOption {
              type = lib.types.str;
            };
            platform.mcp.targets = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    provider = lib.mkOption { type = lib.types.str; };
                    executable = lib.mkOption { type = lib.types.str; };
                    serverLifecycle = lib.mkOption { type = lib.types.str; };
                    port = lib.mkOption { type = lib.types.port; };
                    needsNetwork = lib.mkOption { type = lib.types.bool; };
                    probe = lib.mkOption { type = lib.types.raw; };
                  };
                }
              );
            };
          };

          config.dotfiles.capabilities.agent-session.codex.runtime.executable = fixtureExecutable;
        }
      )
    ];
  };
  target = evaluation.config.dotfiles.platform.mcp.targets.codex;
in
{
  mcp-codex-client-executable-contract =
    assert target.executable == lib.getExe fixtureFront;
    assert target.serverLifecycle == "service";
    pkgs.runCommandLocal "check-mcp-codex-client-executable-contract"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        set -euo pipefail

        if rg -n '/\.local/bin/codex' ${self}/capabilities/agent-session/codex/mcp/module.nix; then
          echo "Codex MCP adapter reconstructs the Capability runtime executable path" >&2
          exit 1
        fi
        touch $out
      '';
}
