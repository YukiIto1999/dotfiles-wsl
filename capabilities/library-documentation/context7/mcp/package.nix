{
  fetchurl,
  mkNpmMcp,
  serverBuilder,
}:

let
  version = "4.1.1";
  pkg = mkNpmMcp {
    pname = "context7-mcp";
    inherit version;
    src = fetchurl {
      url = "https://registry.npmjs.org/@upstash/context7-mcp/-/context7-mcp-${version}.tgz";
      hash = "sha256-y9X4HKN7Qq1UkQmQF7ANEhB+sHW7MRHHoha2MvrJfEo=";
    };
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-MoIGstk087DhxjsuD0nAodxEZ42/kCF4DA4TVXxPhoA=";
  };
in
serverBuilder {
  name = "context7-mcp";
  command = "${pkg}/bin/context7-mcp";
}
