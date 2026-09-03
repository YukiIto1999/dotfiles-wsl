{ lib, pkgs }:

let
  agentgateway = pkgs.callPackage ./agentgateway.nix { };
in
{
  executable,
  serverLifecycle,
  port,
  sessionPolicy,
}:

if serverLifecycle == "service" then
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
                          stdio.cmd = executable;
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
