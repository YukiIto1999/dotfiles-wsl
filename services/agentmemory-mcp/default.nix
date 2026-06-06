{ pkgs }:

let
  # Versions
  agentmemoryMcpVersion = "0.9.26";

  # Sources
  agentmemoryMcpPkg = pkgs.buildNpmPackage {
    pname        = "agentmemory-mcp-deploy";
    version      = agentmemoryMcpVersion;
    src          = ./.;
    npmDepsHash  = "sha256-2Pq4r4JV2Om2dg+bSGqMn+cuUXYdUnqbBf+CqubuhK8=";
    dontNpmBuild = true;
    npmFlags     = [ "--ignore-scripts" "--omit=optional" ];
  };

  mcpProxyBase = pkgs.callPackage ../mcp-proxy-base.nix { };

  runtimeRoot = pkgs.buildEnv {
    name  = "agentmemory-mcp-root";
    paths = [ agentmemoryMcpPkg pkgs.nodejs_24 ];
  };
in
pkgs.dockerTools.buildLayeredImage {
  name      = "agentmemory-mcp";
  tag       = agentmemoryMcpVersion;
  fromImage = mcpProxyBase;
  contents  = [ runtimeRoot ];
  config = {
    Entrypoint   = [ "catatonit" "--" "mcp-proxy" ];
    Cmd          = [ "--port=3006" "--host=0.0.0.0" "--pass-environment" "--" "node"
                     "${agentmemoryMcpPkg}/lib/node_modules/agentmemory-mcp-deploy/node_modules/@agentmemory/mcp/bin.mjs" ];
    ExposedPorts = { "3006/tcp" = { }; };
    Env          = [ "PATH=/app/.venv/bin:${runtimeRoot}/bin:/usr/local/bin:/usr/bin:/bin" ];
  };
}
