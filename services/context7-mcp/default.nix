{ pkgs }:

let
  # Versions
  context7Version = "2.2.5";

  # Sources
  context7Pkg = pkgs.buildNpmPackage {
    pname       = "context7-mcp";
    version     = context7Version;
    src         = pkgs.fetchurl {
      url  = "https://registry.npmjs.org/@upstash/context7-mcp/-/context7-mcp-${context7Version}.tgz";
      hash = "sha256-+3h/SAIYmPQ140XPrt9+fEjdgVUVBe8V4Y0i4YnGs3U=";
    };
    sourceRoot   = "package";
    postPatch    = "cp ${./package-lock.json} ./package-lock.json";
    npmDepsHash  = "sha256-4rWvzzzVNU5U5WG2iKHdNSZqLqDwHQl7w+61yhEJASw=";
    dontNpmBuild = true;
    npmFlags     = [ "--ignore-scripts" ];
  };

  mcpProxyBase = pkgs.callPackage ../mcp-proxy-base.nix { };

  runtimeRoot = pkgs.buildEnv {
    name  = "context7-mcp-root";
    paths = [ context7Pkg pkgs.nodejs_24 ];
  };
in
pkgs.dockerTools.buildLayeredImage {
  name      = "context7-mcp";
  tag       = context7Version;
  fromImage = mcpProxyBase;
  contents  = [ runtimeRoot ];
  config = {
    Entrypoint   = [ "catatonit" "--" "mcp-proxy" ];
    Cmd          = [ "--port=3001" "--host=0.0.0.0" "--" "context7-mcp" ];
    ExposedPorts = { "3001/tcp" = { }; };
    Env          = [ "PATH=/app/.venv/bin:${runtimeRoot}/bin:/usr/local/bin:/usr/bin:/bin" ];
  };
}
