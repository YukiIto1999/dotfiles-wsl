{
  lib,
  fetchurl,
  nodejs,
  mkNpmMcp,
  serverBuilder,
}:

let
  version = "2.86.0";
  pkg = mkNpmMcp {
    pname = "memlab-mcp";
    inherit version;
    src = fetchurl {
      url = "https://registry.npmjs.org/@memlab/mcp-server/-/mcp-server-${version}.tgz";
      hash = "sha256-orLjttxQwd1Dx7MhR1joDiwgaYj+ncBKjj+5EVvzdfc=";
    };
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-qT+aXu9gluo08xxceJgTlbXFPex8N6MBCwQz3HWrLp4=";
    extraPostPatch = ''
      cp ${./package/readonly-server.mjs} dist/readonly-server.js
      cp ${./package/admission.mjs} dist/admission.js
      cp ${./package/supervised-server.mjs} dist/supervised-server.js
    '';
  };
in
serverBuilder {
  name = "memlab-mcp";
  env = {
    NODE_OPTIONS = "--max-old-space-size=1024";
    MEMLAB_ANALYSIS_TIMEOUT_MS = "45000";
  };
  command = "${lib.getExe nodejs} ${pkg}/lib/node_modules/@memlab/mcp-server/dist/supervised-server.js";
}
