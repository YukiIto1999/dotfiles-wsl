{
  pkgs,
}:

# app と iii engine を同梱する upstream image がないため、backend image を Nix で組み立てる
let
  version = "0.9.26";
  iiiVersion = "0.11.2";

  iiiEngineBase = pkgs.dockerTools.pullImage {
    imageName = "iiidev/iii";
    imageDigest = "sha256:15f8d4ed16c0bec350b98f4e18ed04498b1fc5ccc50585e087b736717300cf26";
    finalImageTag = iiiVersion;
    hash = "sha256-AfxRkLYb8Q6UtRQ6FIYaY5KxQOoaon6De5OAG1fleq4=";
  };

  deploymentPackage = pkgs.buildNpmPackage {
    pname = "agentmemory-deploy";
    inherit version;
    src = ./package/engine;
    npmDepsHash = "sha256-GW2kJ1UM6whpLYFvT9ch2APOS4LYD/p2f/uQ6sfA1b8=";
    dontNpmBuild = true;
    npmFlags = [
      "--ignore-scripts"
      "--omit=optional"
    ];
  };
  deploymentRoot = "${deploymentPackage}/lib/node_modules/agentmemory-deploy";
  upstreamRoot = "${deploymentRoot}/node_modules/@agentmemory/agentmemory";

  appRoot = pkgs.runCommand "agentmemory-app-root" { } ''
    mkdir -p $out/opt
    ln -s ${deploymentRoot} $out/opt/agentmemory
  '';

  # iii-exec の sh -c 向けに shell を同梱し /bin のみ link、base image の /lib loader を温存
  runtimeRoot = pkgs.buildEnv {
    name = "agentmemory-root";
    paths = [
      pkgs.nodejs_24
      pkgs.bashInteractive
      pkgs.coreutils
    ];
    pathsToLink = [ "/bin" ];
  };
  shRoot = pkgs.runCommand "agentmemory-sh" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.bashInteractive}/bin/bash $out/bin/sh
  '';

  image = pkgs.dockerTools.buildLayeredImage {
    name = "agentmemory";
    tag = version;
    fromImage = iiiEngineBase;
    contents = [
      appRoot
      runtimeRoot
      shRoot
    ];
    config = {
      Entrypoint = [ "/app/iii" ];
      Cmd = [
        "--config"
        "/app/config.yaml"
      ];
      WorkingDir = "/opt/agentmemory";
      Env = [
        "PATH=/bin:/app:/usr/local/bin:/usr/bin"
        "AGENTMEMORY_DATA_DIR=/data"
        "HOME=/data"
        "XDG_CACHE_HOME=/data/.cache"
        "III_ENV=production"
      ];
    };
  };

in
{
  inherit image upstreamRoot version;
}
