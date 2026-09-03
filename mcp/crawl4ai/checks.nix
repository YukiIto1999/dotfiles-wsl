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
    serverBuilder = mkMcpServer;
    crawl4aiUrl = expectedUrl;
    tokenFile = expectedTokenFile;
  };
  probePackage = pkgs.callPackage ./package.nix {
    serverBuilder = mkMcpServer;
    crawl4aiUrl = expectedUrl;
    tokenFile = pkgs.writeText "crawl4ai-probe-token" "probe-token";
  };
  behaviorPackage = pkgs.callPackage ./package.nix {
    serverBuilder = mkMcpServer;
    crawl4aiUrl = "http://127.0.0.1:18080";
    tokenFile = pkgs.writeText "crawl4ai-behavior-token" "behavior-token";
  };
  behaviorBackend = pkgs.writeText "crawl4ai-behavior-backend.py" ''
    import json
    import sys
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from urllib.parse import parse_qs, urlparse

    observed_path = sys.argv[1]


    class Handler(BaseHTTPRequestHandler):
        def send_json(self, status, body):
            payload = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/mcp/schema":
                self.send_json(
                    200,
                    {
                        "tools": [
                            {
                                "name": "ask",
                                "description": "fixture",
                                "inputSchema": {"type": "object"},
                            }
                        ]
                    },
                )
                return

            if parsed.path == "/ask":
                query = parse_qs(parsed.query)
                if query != {
                    "context_type": ["doc"],
                    "query": ["health"],
                    "max_results": ["1"],
                }:
                    self.send_json(400, {"detail": "unexpected query"})
                    return
                with open(observed_path, "w") as observed:
                    json.dump({"method": "GET", "query": query}, observed)
                self.send_json(200, {"doc_results": [{"text": "health", "score": 1}]})
                return

            self.send_json(404, {"detail": "not found"})

        def do_POST(self):
            self.send_json(405, {"detail": "Method Not Allowed"})

        def log_message(self, format, *args):
            pass


    HTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
  '';
  behaviorDriver = pkgs.writeText "crawl4ai-behavior-driver.py" ''
    import json
    import os
    import subprocess
    import sys


    environment = os.environ.copy()
    environment.pop("SSL_CERT_FILE", None)
    process = subprocess.Popen(
        [sys.argv[1]],
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


    def request(payload):
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())


    initialize = request(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "behavior-check", "version": "1"},
            },
        }
    )
    assert initialize["result"]["serverInfo"]["name"] == "crawl4ai", initialize

    process.stdin.write(
        json.dumps(
            {
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": {},
            }
        )
        + "\n"
    )
    process.stdin.flush()

    tools = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    assert "result" in tools, tools
    assert [tool["name"] for tool in tools["result"]["tools"]] == ["ask"], tools

    call = request(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "ask",
                "arguments": {
                    "context_type": "doc",
                    "query": "health",
                    "max_results": 1,
                },
            },
        }
    )
    assert call["result"].get("isError", False) is False, call
    result = json.loads(call["result"]["content"][0]["text"])
    assert result == {"doc_results": [{"text": "health", "score": 1}]}, result

    process.stdin.close()
    assert process.wait(timeout=10) == 0, process.stderr.read()
  '';
  front = hostConfig.dotfiles.mcp.fronts.crawl4ai;
  target = hostConfig.dotfiles.mcp.targets.crawl4ai;
  token = hostConfig.sops.secrets."crawl4ai/api_token";
  expectedRestartUnit = "${front.service}.service";
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
    serverBuilder = spec: spec;
    crawl4aiUrl = expectedUrl;
    tokenFile = expectedTokenFile;
  };
  expectedIsolationSpecJSON = builtins.toJSON expectedIsolationSpec;
  expectedIsolationTarget = {
    provider = "crawl4ai";
    executable = lib.getExe isolationPackage;
    serverLifecycle = "service";
    port = expectedPort;
    needsNetwork = false;
    waitUnits = expectedWaitUnits;
    probe = {
      tool = "ask";
      args = {
        context_type = "doc";
        query = "health";
        max_results = 1;
      };
      timeout = 60;
    };
  };
  expectedIsolationTargetJSON = builtins.toJSON expectedIsolationTarget;

  mkIsolationProjection =
    sopsStub:
    let
      isolationPkgs = pkgs // {
        callPackage =
          path: args:
          if path == ../package/mk-server.nix then
            spec:
            assert builtins.toJSON spec == expectedIsolationSpecJSON;
            isolationPackage
          else
            pkgs.callPackage path args;
      };
      evaluation = lib.evalModules {
        specialArgs.pkgs = isolationPkgs;
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
                dotfiles.mcp.targets = lib.mkOption {
                  default = { };
                  type = lib.types.attrsOf (
                    lib.types.submodule {
                      options = {
                        provider = lib.mkOption { type = lib.types.str; };
                        executable = lib.mkOption { type = lib.types.str; };
                        serverLifecycle = lib.mkOption { type = lib.types.str; };
                        port = lib.mkOption { type = lib.types.port; };
                        needsNetwork = lib.mkOption {
                          type = lib.types.bool;
                          default = false;
                        };
                        waitUnits = lib.mkOption { type = lib.types.listOf lib.types.str; };
                        probe = lib.mkOption { type = lib.types.raw; };
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
      isolatedTarget = evaluation.config.dotfiles.mcp.targets.crawl4ai;
    in
    builtins.toJSON {
      inherit (isolatedTarget)
        executable
        needsNetwork
        port
        probe
        provider
        serverLifecycle
        waitUnits
        ;
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
    assert token.restartUnits == [ expectedRestartUnit ];
    assert lib.elem (lib.getExe frontPackage) execTokens;
    assert poisonIsolationProjection == expectedIsolationTargetJSON;
    assert canaryAIsolationProjection == expectedIsolationTargetJSON;
    assert canaryBIsolationProjection == expectedIsolationTargetJSON;
    pkgs.runCommandLocal "check-crawl4ai-front"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.jq
          pkgs.python3
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

        ${pkgs.python3}/bin/python ${behaviorBackend} "$PWD/observed.json" &
        backend_pid=$!
        trap 'kill "$backend_pid" 2>/dev/null || true' EXIT
        curl --silent --show-error --fail --retry 20 --retry-all-errors --retry-delay 0 \
          http://127.0.0.1:18080/mcp/schema >/dev/null
        timeout 20 ${pkgs.python3}/bin/python ${behaviorDriver} ${lib.getExe behaviorPackage}
        jq -e \
          '. == {
            method: "GET",
            query: {
              context_type: ["doc"],
              query: ["health"],
              max_results: ["1"]
            }
          }' \
          observed.json >/dev/null

        touch $out
      '';
}
