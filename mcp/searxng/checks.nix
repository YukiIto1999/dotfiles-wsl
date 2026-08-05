{
  helpers,
  lib,
  pkgs,
  hostConfig,
  ...
}:

let
  expectedUrl = "http://127.0.0.1:8080";
  expectedPort = 8775;
  expectedWaitUnits = [ "docker-searxng.service" ];

  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../package/mk-npm.nix { };
  frontPackage = pkgs.callPackage ./package.nix {
    inherit mkMcpServer mkNpmMcp;
    searxngUrl = expectedUrl;
  };
  front = hostConfig.dotfiles.mcp.fronts.searxng;
  target = hostConfig.dotfiles.mcp.targets.searxng;
  execStart = hostConfig.systemd.services.${front.service}.serviceConfig.ExecStart;
  execTokens = helpers.execTokens.tokensOf execStart;
in
{
  searxng-front =
    assert target.port == expectedPort;
    assert target.waitUnits == expectedWaitUnits;
    assert lib.elem (lib.getExe frontPackage) execTokens;
    pkgs.runCommandLocal "check-searxng-front"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail

        grep -Fqx 'export SEARXNG_URL="${expectedUrl}"' ${lib.getExe frontPackage}
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

        jq -e '.result.serverInfo.name == "ihor-sokoliuk/mcp-searxng"' response.json >/dev/null
        touch $out
      '';
}
