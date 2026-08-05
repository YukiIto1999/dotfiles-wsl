{
  pkgs,
  mkMcpServer,
  agentmemoryUrl,
  version,
}:
let
  mcpPkg = pkgs.buildNpmPackage {
    pname = "agentmemory-mcp-deploy";
    inherit version;
    src = ./package/mcp;
    npmDepsHash = "sha256-2Pq4r4JV2Om2dg+bSGqMn+cuUXYdUnqbBf+CqubuhK8=";
    dontNpmBuild = true;
    npmFlags = [
      "--ignore-scripts"
      "--omit=optional"
    ];
  };
in
mkMcpServer {
  name = "agentmemory-mcp";
  env.AGENTMEMORY_URL = agentmemoryUrl;
  command = "${pkgs.nodejs_24}/bin/node ${mcpPkg}/lib/node_modules/agentmemory-mcp-deploy/node_modules/@agentmemory/mcp/bin.mjs";
}
