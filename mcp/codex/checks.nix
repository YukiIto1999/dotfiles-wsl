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
      if path == ../package/mk-server.nix then
        spec:
        assert
          spec == {
            name = "codex-mcp";
            command = expectedCommand;
          };
        fixtureFront
      else if path == ../package/serve-over-proxy.nix then
        executable: port: "proxy:${executable}:${toString port}"
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
            host.homeDir = lib.mkOption { type = lib.types.str; };
            agents.clientExecutables = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
            };
            mcp.targets = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    provider = lib.mkOption { type = lib.types.str; };
                    port = lib.mkOption { type = lib.types.port; };
                    serve = lib.mkOption { type = lib.types.functionTo lib.types.str; };
                    needsNetwork = lib.mkOption { type = lib.types.bool; };
                    probe = lib.mkOption { type = lib.types.raw; };
                  };
                }
              );
            };
          };

          config.dotfiles = {
            host.homeDir = "/fixture/legacy-home";
            agents.clientExecutables.codex = fixtureExecutable;
          };
        }
      )
    ];
  };
  target = evaluation.config.dotfiles.mcp.targets.codex;
in
{
  mcp-codex-client-executable-contract =
    assert target.serve 9876 == "proxy:${lib.getExe fixtureFront}:9876";
    pkgs.runCommandLocal "check-mcp-codex-client-executable-contract"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        set -euo pipefail

        if rg -n '/\.local/bin/codex' ${self}/mcp/codex/module.nix; then
          echo "mcp/codex reconstructs the Codex client executable path" >&2
          exit 1
        fi
        touch $out
      '';
}
