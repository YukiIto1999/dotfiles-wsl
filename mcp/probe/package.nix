{
  pkgs,
  mkMcpServer,
  mkNpmMcp,
}:

# user の repo を検索する code search、probe binary を PATH に同梱
let
  version = "0.6.0-rc319";

  probePkg = mkNpmMcp {
    pname = "probe-mcp";
    inherit version;
    registryPath = "@probelabs/probe";
    hash = "sha256-pis7TU9WWL/EEyfkQfpjkRWMt3U6KwxjysrW4SNoOR0=";
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-TKYjQiGW7WwBjDJfS6OhEC79NgfLwvCSHExJnwP4WZ8=";
    extraPostPatch = ''
      ${pkgs.jq}/bin/jq 'del(.devDependencies, .scripts)' package.json > package.json.tmp
      mv package.json.tmp package.json
    '';
    npmInstallFlags = [ "--ignore-scripts" ];
    makeCacheWritable = true;
  };

  probeBin = pkgs.runCommand "probe-bin" { } ''
    mkdir -p $out/bin
    tar -xzf ${
      pkgs.fetchurl {
        url = "https://github.com/probelabs/probe/releases/download/v${version}/probe-v${version}-x86_64-unknown-linux-musl.tar.gz";
        hash = "sha256-eM+s72u407OAj4CW+XMmGRSytb5NijaYx8WFpAk8gKE=";
      }
    } -C /tmp
    install -m755 /tmp/probe-v${version}-x86_64-unknown-linux-musl/probe $out/bin/probe
  '';
in
mkMcpServer {
  name = "probe-mcp";
  env.PATH = "${probeBin}/bin:$PATH";
  env.PROBE_PATH = "${probeBin}/bin/probe";
  command = "${pkgs.nodejs_24}/bin/node ${probePkg}/lib/node_modules/@probelabs/probe/build/mcp/index.js";
}
