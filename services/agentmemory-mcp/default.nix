{ pkgs, agentmemoryUrl }:

# agentmemory MCP server (stdio front to the agentmemory engine).
let
  version = "0.9.26";

  pkg = pkgs.buildNpmPackage {
    pname        = "agentmemory-mcp-deploy";
    inherit version;
    src          = ./.;
    npmDepsHash  = "sha256-2Pq4r4JV2Om2dg+bSGqMn+cuUXYdUnqbBf+CqubuhK8=";
    dontNpmBuild = true;
    npmFlags     = [ "--ignore-scripts" "--omit=optional" ];
  };
in
pkgs.writeShellScriptBin "agentmemory-mcp" ''
  export AGENTMEMORY_URL=${agentmemoryUrl}
  exec ${pkgs.nodejs_24}/bin/node ${pkg}/lib/node_modules/agentmemory-mcp-deploy/node_modules/@agentmemory/mcp/bin.mjs "$@"
''
