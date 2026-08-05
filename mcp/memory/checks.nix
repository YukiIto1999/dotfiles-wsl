{
  helpers,
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  expectedVersion = "0.9.26";
  expectedUrl = "http://127.0.0.1:3111";
  expectedPort = 8774;
  expectedWaitUnits = [ "docker-agentmemory.service" ];

  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  frontPackage = pkgs.callPackage ./package.nix {
    serverBuilder = mkMcpServer;
    agentmemoryUrl = expectedUrl;
    version = expectedVersion;
  };
  front = hostConfig.dotfiles.mcp.fronts.memory;
  target = hostConfig.dotfiles.mcp.targets.memory;
  execStart = hostConfig.systemd.services.${front.service}.serviceConfig.ExecStart;
  execTokens = helpers.execTokens.tokensOf execStart;
in
{
  agentmemory-front =
    assert target.port == expectedPort;
    assert target.waitUnits == expectedWaitUnits;
    assert lib.elem (lib.getExe frontPackage) execTokens;
    pkgs.runCommandLocal "check-agentmemory-front"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail

        grep -Fqx 'export AGENTMEMORY_URL="${expectedUrl}"' ${lib.getExe frontPackage}
        printf '%s\n' '${
          builtins.toJSON {
            jsonrpc = "2.0";
            id = 1;
            method = "initialize";
            params = {
              protocolVersion = "2025-06-18";
              capabilities = { };
              clientInfo = {
                name = "nix-check";
                version = "1";
              };
            };
          }
        }' \
          | timeout 10 ${lib.getExe frontPackage} > response.json 2> front.log

        jq -e \
          --arg version '${expectedVersion}' \
          '.result.serverInfo == { name: "agentmemory", version: $version }' \
          response.json >/dev/null
        grep -Fq 'Standalone MCP server v${expectedVersion} starting' front.log
        touch $out
      '';
}
