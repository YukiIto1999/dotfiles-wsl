{ pkgs }:

let
  # Versions
  githubMcpVersion = "1.0.5";
  mcpProxyTag      = "v0.12.0";

  # Sources
  githubMcpTar = pkgs.fetchurl {
    url  = "https://github.com/github/github-mcp-server/releases/download/v${githubMcpVersion}/github-mcp-server_Linux_x86_64.tar.gz";
    hash = "sha256-IBCC9WmoRurv1DGPE7zLXZInws7EUDfR0pLugxERc8E=";
  };

  mcpProxyBase = pkgs.dockerTools.pullImage {
    imageName     = "sparfenyuk/mcp-proxy";
    imageDigest   = "sha256:8c69321db9cfcd39b1f8e13cabf433ba60669adeb8e44ab39330c43de89f0578";
    finalImageTag = mcpProxyTag;
    hash          = "sha256-Zqg4hm3P5ZTYBChtn1NhvPGlTWi/1ch3BrzoZB/WMWM=";
  };

  runtimeRoot = pkgs.runCommand "github-mcp-root" { } ''
    mkdir -p $out/usr/local/bin
    tar -xzf ${githubMcpTar} -C /tmp
    install -m 755 /tmp/github-mcp-server $out/usr/local/bin/github-mcp-server
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name      = "github-mcp";
  tag       = githubMcpVersion;
  fromImage = mcpProxyBase;
  contents  = [ runtimeRoot ];
  config = {
    Entrypoint   = [ "catatonit" "--" "mcp-proxy" ];
    Cmd          = [ "--port=3002" "--host=0.0.0.0" "--pass-environment" "--" "github-mcp-server" "stdio" ];
    ExposedPorts = { "3002/tcp" = { }; };
    Env          = [ "PATH=/app/.venv/bin:/usr/local/bin:/usr/bin:/bin" ];
  };
}
