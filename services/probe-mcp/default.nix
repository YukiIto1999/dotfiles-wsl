{ pkgs }:

let
  # Versions
  probeVersion = "0.6.0-rc319";
  mcpProxyTag  = "v0.12.0";

  # Sources
  probePkg = pkgs.buildNpmPackage {
    pname       = "probe-mcp";
    version     = probeVersion;
    src         = pkgs.fetchurl {
      url  = "https://registry.npmjs.org/@probelabs/probe/-/probe-${probeVersion}.tgz";
      hash = "sha256-pis7TU9WWL/EEyfkQfpjkRWMt3U6KwxjysrW4SNoOR0=";
    };
    sourceRoot   = "package";
    postPatch    = ''
      cp ${./package-lock.json} ./package-lock.json
      ${pkgs.jq}/bin/jq 'del(.devDependencies, .scripts)' package.json > package.json.tmp
      mv package.json.tmp package.json
    '';
    npmDepsHash  = "sha256-TKYjQiGW7WwBjDJfS6OhEC79NgfLwvCSHExJnwP4WZ8=";
    dontNpmBuild = true;
    npmFlags           = [ "--ignore-scripts" ];
    npmInstallFlags    = [ "--ignore-scripts" ];
    makeCacheWritable  = true;
  };

  probeTar = pkgs.fetchurl {
    url  = "https://github.com/probelabs/probe/releases/download/v${probeVersion}/probe-v${probeVersion}-x86_64-unknown-linux-musl.tar.gz";
    hash = "sha256-eM+s72u407OAj4CW+XMmGRSytb5NijaYx8WFpAk8gKE=";
  };

  probeBin = pkgs.runCommand "probe-bin" { } ''
    mkdir -p $out/bin
    tar -xzf ${probeTar} -C /tmp
    install -m 755 /tmp/probe-v${probeVersion}-x86_64-unknown-linux-musl/probe $out/bin/probe
  '';

  mcpProxyBase = pkgs.dockerTools.pullImage {
    imageName     = "sparfenyuk/mcp-proxy";
    imageDigest   = "sha256:8c69321db9cfcd39b1f8e13cabf433ba60669adeb8e44ab39330c43de89f0578";
    finalImageTag = mcpProxyTag;
    hash          = "sha256-Zqg4hm3P5ZTYBChtn1NhvPGlTWi/1ch3BrzoZB/WMWM=";
  };

  runtimeRoot = pkgs.buildEnv {
    name  = "probe-mcp-root";
    paths = [ probePkg probeBin pkgs.nodejs_24 ];
    ignoreCollisions = true;
    postBuild = ''
      rm -f $out/bin/probe
      ln -s ${probeBin}/bin/probe $out/bin/probe
    '';
  };
in
pkgs.dockerTools.buildLayeredImage {
  name      = "probe-mcp";
  tag       = probeVersion;
  fromImage = mcpProxyBase;
  contents  = [ runtimeRoot ];
  config = {
    Entrypoint   = [ "catatonit" "--" "mcp-proxy" ];
    Cmd          = [ "--port=3005" "--host=0.0.0.0" "--" "node" "${probePkg}/lib/node_modules/@probelabs/probe/build/mcp/index.js" ];
    ExposedPorts = { "3005/tcp" = { }; };
    Env          = [ "PATH=/app/.venv/bin:${runtimeRoot}/bin:/usr/local/bin:/usr/bin:/bin" ];
  };
}
