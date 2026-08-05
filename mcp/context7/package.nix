{ mkNpmMcp, serverBuilder }:

# context7 cloud に接続する library docs front、backend なし
let
  pkg = mkNpmMcp {
    pname = "context7-mcp";
    version = "3.2.5";
    registryPath = "@upstash/context7-mcp";
    hash = "sha256-64AdyLbymzFUgfEx+/UlipkpL78zJbDvLKKlrFJMk8s=";
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-d+fP6Oxkbv+99pMY0tmFRWQwDFlVcAudV2lM6WUbe3I=";
  };
in
serverBuilder {
  name = "context7-mcp";
  command = "${pkg}/bin/context7-mcp";
}
