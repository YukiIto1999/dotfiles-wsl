{ pkgs }:

# Shared mcp-proxy base image for context7 / github / probe
pkgs.dockerTools.pullImage {
  imageName     = "sparfenyuk/mcp-proxy";
  imageDigest   = "sha256:8c69321db9cfcd39b1f8e13cabf433ba60669adeb8e44ab39330c43de89f0578";
  finalImageTag = "v0.12.0";
  hash          = "sha256-Zqg4hm3P5ZTYBChtn1NhvPGlTWi/1ch3BrzoZB/WMWM=";
}
