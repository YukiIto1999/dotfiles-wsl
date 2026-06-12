{ pkgs }:

let
  # バージョン
  agentmemoryVersion = "0.9.26";
  iiiVersion         = "0.11.2";

  # 取得元
  iiiEngineBase = pkgs.dockerTools.pullImage {
    imageName     = "iiidev/iii";
    imageDigest   = "sha256:15f8d4ed16c0bec350b98f4e18ed04498b1fc5ccc50585e087b736717300cf26";
    finalImageTag = iiiVersion;
    hash          = "sha256-AfxRkLYb8Q6UtRQ6FIYaY5KxQOoaon6De5OAG1fleq4=";
  };

  # iii-sdk を engine と同 version に固定
  agentmemoryPkg = pkgs.buildNpmPackage {
    pname        = "agentmemory-deploy";
    version      = agentmemoryVersion;
    src          = ./.;
    npmDepsHash  = "sha256-GW2kJ1UM6whpLYFvT9ch2APOS4LYD/p2f/uQ6sfA1b8=";
    dontNpmBuild = true;
    npmFlags     = [ "--ignore-scripts" "--omit=optional" ];
  };

  agentmemoryModule = "${agentmemoryPkg}/lib/node_modules/agentmemory-deploy";

  appRoot = pkgs.runCommand "agentmemory-app-root" { } ''
    mkdir -p $out/opt
    ln -s ${agentmemoryModule} $out/opt/agentmemory
  '';

  # iii-exec の sh -c 起動用に shell 同梱、/bin のみ link し base の /lib 動的リンカ温存
  runtimeRoot = pkgs.buildEnv {
    name        = "agentmemory-root";
    paths       = [ pkgs.nodejs_24 pkgs.bashInteractive pkgs.coreutils ];
    pathsToLink = [ "/bin" ];
  };
  shRoot = pkgs.runCommand "agentmemory-sh" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.bashInteractive}/bin/bash $out/bin/sh
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name      = "agentmemory";
  tag       = agentmemoryVersion;
  fromImage = iiiEngineBase;
  contents  = [ appRoot runtimeRoot shRoot ];
  config = {
    Entrypoint   = [ "/app/iii" ];
    Cmd          = [ "--config" "/app/config.yaml" ];
    WorkingDir   = "/opt/agentmemory";
    # 記載のみ、port の正は modules/mcp/endpoints.nix
    ExposedPorts = { "3111/tcp" = { }; "3112/tcp" = { }; };
    Env = [
      "PATH=/bin:/app:/usr/local/bin:/usr/bin"
      "AGENTMEMORY_DATA_DIR=/data"
      "HOME=/data"
      "XDG_CACHE_HOME=/data/.cache"
      "III_ENV=production"
    ];
  };
}
