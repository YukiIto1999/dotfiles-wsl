{ pkgs }:

# context7 MCP server. Exposes bin/context7-mcp; the gateway spawns it over stdio.
let
  version = "2.2.5";
in
pkgs.buildNpmPackage {
  pname   = "context7-mcp";
  inherit version;

  src = pkgs.fetchurl {
    url  = "https://registry.npmjs.org/@upstash/context7-mcp/-/context7-mcp-${version}.tgz";
    hash = "sha256-+3h/SAIYmPQ140XPrt9+fEjdgVUVBe8V4Y0i4YnGs3U=";
  };

  sourceRoot   = "package";
  postPatch    = "cp ${./package-lock.json} ./package-lock.json";
  npmDepsHash  = "sha256-4rWvzzzVNU5U5WG2iKHdNSZqLqDwHQl7w+61yhEJASw=";
  dontNpmBuild = true;
  npmFlags     = [ "--ignore-scripts" ];

  meta.mainProgram = "context7-mcp";
}
