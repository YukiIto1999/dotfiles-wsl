{ pkgs, mkMcpServer }:

# context7 cloud に接続する library docs front、backend なし
let
  version = "2.2.5";
  pkg = pkgs.buildNpmPackage {
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
  };
in
mkMcpServer {
  name    = "context7-mcp";
  command = "${pkg}/bin/context7-mcp";
}
