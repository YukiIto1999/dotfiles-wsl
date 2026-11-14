{ lib, pkgs }:

let
  agentgateway = pkgs.callPackage ./agentgateway.nix { };
in
{
  executable,
  serverLifecycle,
  lazyDiscovery ? false,
  port,
  sessionPolicy,
}:

if serverLifecycle == "service" then
  assert lib.assertMsg (!lazyDiscovery) "lazy MCP discovery requires a session server lifecycle";
  "${lib.getExe pkgs.mcp-proxy} --host 127.0.0.1 --port ${toString port} --stateless -- ${executable}"
else if serverLifecycle == "session" then
  let
    sessionTtlSeconds = sessionPolicy.idleSeconds + sessionPolicy.frontGraceSeconds;
    config = (pkgs.formats.yaml { }).generate "mcp-session-front-${toString port}.yaml" {
      config = {
        mcp.sessionTtl = "${toString sessionTtlSeconds}s";
        adminAddr = "off";
        statsAddr = "off";
        readinessAddr = "off";
      };
      binds = [
        {
          address = "127.0.0.1";
          inherit port;
          listeners = [
            {
              routes = [
                {
                  backends = [
                    {
                      mcp.targets = [
                        {
                          name = "server";
                          stdio = {
                            cmd = executable;
                          }
                          // lib.optionalAttrs lazyDiscovery { lazy_discovery = true; };
                        }
                      ];
                    }
                  ];
                }
              ];
            }
          ];
        }
      ];
    };
  in
  "${lib.getExe agentgateway} -f ${config}"
else
  throw "unsupported MCP server lifecycle: ${serverLifecycle}"
