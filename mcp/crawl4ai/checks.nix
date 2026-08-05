{
  helpers,
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  expectedUrl = "http://127.0.0.1:11235";
  expectedTokenFile = "/run/secrets/crawl4ai/api_token";
  expectedPort = 8773;
  expectedWaitUnits = [ "docker-crawl4ai.service" ];

  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  frontPackage = pkgs.callPackage ./package.nix {
    inherit mkMcpServer;
    crawl4aiUrl = expectedUrl;
    tokenFile = expectedTokenFile;
  };
  probePackage = pkgs.callPackage ./package.nix {
    inherit mkMcpServer;
    crawl4aiUrl = expectedUrl;
    tokenFile = pkgs.writeText "crawl4ai-probe-token" "probe-token";
  };
  front = hostConfig.my.contract.mcp.fronts.crawl4ai;
  target = hostConfig.my.mcp.targets.crawl4ai;
  execStart = hostConfig.systemd.services.${front.service}.serviceConfig.ExecStart;
  execTokens = helpers.execTokens.tokensOf execStart;

  isolationPackage =
    pkgs.runCommandLocal "crawl4ai-isolation-front"
      {
        meta.mainProgram = "crawl4ai-isolation-front";
      }
      ''
        mkdir -p "$out/bin"
        touch "$out/bin/crawl4ai-isolation-front"
      '';
  expectedIsolationSpec = import ./package.nix {
    inherit pkgs;
    mkMcpServer = spec: spec;
    crawl4aiUrl = expectedUrl;
    tokenFile = expectedTokenFile;
  };
  expectedIsolationSpecJSON = builtins.toJSON expectedIsolationSpec;
  expectedIsolationTarget = {
    port = expectedPort;
    serve = "proxy:${lib.getExe isolationPackage}";
    waitUnits = expectedWaitUnits;
  };
  expectedIsolationTargetJSON = builtins.toJSON expectedIsolationTarget;

  mkIsolationProjection =
    sopsStub:
    let
      evaluation = lib.evalModules {
        specialArgs = {
          inherit pkgs;
          mkMcpServer =
            spec:
            assert builtins.toJSON spec == expectedIsolationSpecJSON;
            isolationPackage;
          serveOverProxy = executable: "proxy:${executable}";
        };
        modules = [
          ./module.nix
          (
            { lib, ... }:
            {
              options = {
                dotfiles.containers = {
                  services.crawl4ai = lib.mkOption {
                    readOnly = true;
                    type = lib.types.submodule {
                      options = {
                        endpoints.http.url = lib.mkOption {
                          type = lib.types.str;
                          readOnly = true;
                        };
                        units = lib.mkOption {
                          type = lib.types.listOf lib.types.str;
                          readOnly = true;
                        };
                      };
                    };
                  };
                  crawl4ai.credentials.apiTokenFile = lib.mkOption {
                    type = lib.types.str;
                    readOnly = true;
                  };
                };
                my.mcp.targets = lib.mkOption {
                  default = { };
                  type = lib.types.attrsOf (
                    lib.types.submodule {
                      options = {
                        port = lib.mkOption { type = lib.types.port; };
                        serve = lib.mkOption { type = lib.types.str; };
                        waitUnits = lib.mkOption { type = lib.types.listOf lib.types.str; };
                      };
                    }
                  );
                };
                sops = lib.mkOption { type = lib.types.raw; };
              };

              config = {
                dotfiles.containers = {
                  services.crawl4ai = {
                    endpoints.http.url = expectedUrl;
                    units = expectedWaitUnits;
                  };
                  crawl4ai.credentials.apiTokenFile = expectedTokenFile;
                };
                sops = sopsStub;
              };
            }
          )
        ];
      };
      isolatedTarget = evaluation.config.my.mcp.targets.crawl4ai;
    in
    builtins.toJSON {
      inherit (isolatedTarget) port serve waitUnits;
    };

  poisonIsolationProjection = mkIsolationProjection (throw "Crawl4AI front must not depend on SOPS");
  canaryAIsolationProjection = mkIsolationProjection {
    secrets."crawl4ai/api_token".path = "/run/forbidden/crawl4ai-canary-a";
  };
  canaryBIsolationProjection = mkIsolationProjection {
    secrets."crawl4ai/api_token".path = "/run/forbidden/crawl4ai-canary-b";
  };
in
{
  crawl4ai-front =
    assert target.port == expectedPort;
    assert target.waitUnits == expectedWaitUnits;
    assert lib.elem (lib.getExe frontPackage) execTokens;
    assert poisonIsolationProjection == expectedIsolationTargetJSON;
    assert canaryAIsolationProjection == expectedIsolationTargetJSON;
    assert canaryBIsolationProjection == expectedIsolationTargetJSON;
    pkgs.runCommandLocal "check-crawl4ai-front"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail

        grep -Fqx 'export CRAWL4AI_URL="${expectedUrl}"' ${lib.getExe frontPackage}
        grep -Fqx 'export CRAWL4AI_TOKEN_FILE="${expectedTokenFile}"' ${lib.getExe frontPackage}
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
          | timeout 10 ${lib.getExe probePackage} > response.json 2> front.log

        jq -e '.result.serverInfo.name == "crawl4ai"' response.json >/dev/null
        touch $out
      '';
}
