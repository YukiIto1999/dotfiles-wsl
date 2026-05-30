{ pkgs }:

let
  # Versions
  crawl4aiMcpVersion = "0.8.6";

  # Sources
  mcpProxyBase = pkgs.callPackage ../mcp-proxy-base.nix { };

  runtimeRoot = pkgs.runCommand "crawl4ai-mcp-root" { } ''
    mkdir -p $out/app
    cp ${./server.py} $out/app/server.py
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name      = "crawl4ai-mcp";
  tag       = crawl4aiMcpVersion;
  fromImage = mcpProxyBase;
  contents  = [ runtimeRoot ];
  config = {
    Entrypoint   = [ "catatonit" "--" "mcp-proxy" ];
    Cmd          = [ "--port=11236" "--host=0.0.0.0" "--pass-environment" "--" "python3" "/app/server.py" ];
    ExposedPorts = { "11236/tcp" = { }; };
  };
}
