{ pkgs, mkMcpServer, searxngUrl }:

# self-hosted SearXNG への stdio front
let
  version = "1.4.0";
  pkg = pkgs.buildNpmPackage {
    pname   = "mcp-searxng";
    inherit version;
    src = pkgs.fetchurl {
      url  = "https://registry.npmjs.org/mcp-searxng/-/mcp-searxng-${version}.tgz";
      hash = "sha256-XZhYgbpNjtAvcM72j4EUHvlABk4eaNbFdvG4mbKvLKc=";
    };
    sourceRoot   = "package";
    postPatch    = "cp ${./package-lock.json} ./package-lock.json";
    npmDepsHash  = "sha256-Lh1UoM8zSMFji/TkqDAOiRtFRrQ/jqn5TbONySj9ckg=";
    dontNpmBuild = true;
    npmFlags     = [ "--ignore-scripts" ];
  };
in
mkMcpServer {
  name    = "searxng-mcp";
  env.SEARXNG_URL = searxngUrl;
  command = "${pkg}/bin/mcp-searxng";
}
