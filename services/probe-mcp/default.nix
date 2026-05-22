{ pkgs }:

let
  # Versions
  probeVersion = "0.6.0-rc316";
  mcpProxyTag  = "v0.12.0";

  # Sources
  probeTar = pkgs.fetchurl {
    url  = "https://github.com/probelabs/probe/releases/download/v${probeVersion}/probe-v${probeVersion}-x86_64-unknown-linux-musl.tar.gz";
    hash = "sha256-nQ38pxXqnbfhWqcin1rAVKZ1K0Gc/BPkKJ6u+ALQ5K4=";
  };

  mcpProxyBase = pkgs.dockerTools.pullImage {
    imageName     = "sparfenyuk/mcp-proxy";
    imageDigest   = "sha256:8c69321db9cfcd39b1f8e13cabf433ba60669adeb8e44ab39330c43de89f0578";
    finalImageTag = mcpProxyTag;
    hash          = "sha256-Zqg4hm3P5ZTYBChtn1NhvPGlTWi/1ch3BrzoZB/WMWM=";
  };

  runtimeRoot = pkgs.runCommand "probe-mcp-root" { } ''
    mkdir -p $out/usr/local/bin
    tar -xzf ${probeTar} -C /tmp
    install -m 755 /tmp/probe-v${probeVersion}-x86_64-unknown-linux-musl/probe $out/usr/local/bin/probe
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name      = "probe-mcp";
  tag       = probeVersion;
  fromImage = mcpProxyBase;
  contents  = [ runtimeRoot ];
  config = {
    Entrypoint   = [ "catatonit" "--" "mcp-proxy" ];
    Cmd          = [ "--port=3005" "--host=0.0.0.0" "--" "probe" "mcp" ];
    ExposedPorts = { "3005/tcp" = { }; };
    Env          = [ "PATH=/app/.venv/bin:/usr/local/bin:/usr/bin:/bin" ];
  };
}
