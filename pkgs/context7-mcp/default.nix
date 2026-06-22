{ mkMcpServer, mkNpmMcp }:

# context7 cloud に接続する library docs front、backend なし
let
  pkg = mkNpmMcp {
    pname        = "context7-mcp";
    version      = "2.2.5";
    registryPath = "@upstash/context7-mcp";
    hash         = "sha256-+3h/SAIYmPQ140XPrt9+fEjdgVUVBe8V4Y0i4YnGs3U=";
    lockFile     = ./package-lock.json;
    npmDepsHash  = "sha256-4rWvzzzVNU5U5WG2iKHdNSZqLqDwHQl7w+61yhEJASw=";
  };
in
mkMcpServer {
  name    = "context7-mcp";
  command = "${pkg}/bin/context7-mcp";
}
