{
  lib,
  pkgs,
  mkMcpServer,
  agentmemoryUrl,
}:

# app と iii engine を同梱する upstream image がない自前 build backend、image と front を同一 version で返す
let
  version = "0.9.26";
  iiiVersion = "0.11.2";

  iiiEngineBase = pkgs.dockerTools.pullImage {
    imageName = "iiidev/iii";
    imageDigest = "sha256:15f8d4ed16c0bec350b98f4e18ed04498b1fc5ccc50585e087b736717300cf26";
    finalImageTag = iiiVersion;
    hash = "sha256-AfxRkLYb8Q6UtRQ6FIYaY5KxQOoaon6De5OAG1fleq4=";
  };

  enginePkg = pkgs.buildNpmPackage {
    pname = "agentmemory-deploy";
    inherit version;
    src = ./engine;
    npmDepsHash = "sha256-GW2kJ1UM6whpLYFvT9ch2APOS4LYD/p2f/uQ6sfA1b8=";
    dontNpmBuild = true;
    npmFlags = [
      "--ignore-scripts"
      "--omit=optional"
    ];
  };
  engineModule = "${enginePkg}/lib/node_modules/agentmemory-deploy";

  appRoot = pkgs.runCommand "agentmemory-app-root" { } ''
    mkdir -p $out/opt
    ln -s ${engineModule} $out/opt/agentmemory
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

  mcpPkg = pkgs.buildNpmPackage {
    pname = "agentmemory-mcp-deploy";
    inherit version;
    src = ./mcp;
    npmDepsHash = "sha256-2Pq4r4JV2Om2dg+bSGqMn+cuUXYdUnqbBf+CqubuhK8=";
    dontNpmBuild = true;
    npmFlags = [
      "--ignore-scripts"
      "--omit=optional"
    ];
  };

  front = mkMcpServer {
    name = "agentmemory-mcp";
    env.AGENTMEMORY_URL = agentmemoryUrl;
    command = "${pkgs.nodejs_24}/bin/node ${mcpPkg}/lib/node_modules/agentmemory-mcp-deploy/node_modules/@agentmemory/mcp/bin.mjs";
  };

  agentmemoryPkg = "${engineModule}/node_modules/@agentmemory/agentmemory";

  # CLI lifecycle hook。engine 同梱 script を stable 名の bin で公開し REST /observe へ送る
  mkHook =
    name: extraEnv:
    pkgs.writeShellScriptBin "agentmemory-hook-${name}" ''
      export AGENTMEMORY_URL=${agentmemoryUrl}
      ${extraEnv}exec ${agentmemoryPkg}/dist/hooks/${name}.mjs "$@"
    '';

  hookNames = [
    "session-start"
    "session-end"
    "stop"
    "prompt-submit"
    "pre-tool-use"
    "post-tool-use"
    "post-tool-failure"
    "pre-compact"
    "notification"
    "subagent-start"
    "subagent-stop"
    "task-completed"
  ];

  hooks = pkgs.symlinkJoin {
    name = "agentmemory-hooks-${version}";
    paths = lib.map (
      name:
      mkHook name (
        lib.optionalString (name == "session-start") "export AGENTMEMORY_INJECT_CONTEXT=true\n"
      )
    ) hookNames;
  };

  opencodePlugin = "${agentmemoryPkg}/plugin/opencode/agentmemory-capture.ts";
in
{
  inherit
    image
    front
    hooks
    opencodePlugin
    ;
}
