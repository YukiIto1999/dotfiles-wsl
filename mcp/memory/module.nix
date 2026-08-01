{
  config,
  lib,
  pkgs,
  mkMcpServer,
  mkMcpBackend,
  ...
}:

let
  uid = "65532";

  httpPort = "3111";
  # stream port は publish しない、engine config 内部専用で consumer なし
  streamPort = "3112";

  agentmemory = pkgs.callPackage ./package.nix {
    inherit mkMcpServer;
    agentmemoryUrl = "http://127.0.0.1:${httpPort}";
  };

  agentmemoryConfig = pkgs.replaceVars ./assets/engine-config.yaml {
    inherit httpPort streamPort;
  };

  backend = mkMcpBackend "agentmemory" {
    image = "${agentmemory.image.imageName}:${agentmemory.image.imageTag}";
    imageFile = agentmemory.image;
    volumes = [
      "${agentmemoryConfig}:/app/config.yaml:ro"
      "/var/lib/agentmemory/data:/data"
    ];
    environmentFiles = [ config.sops.templates."agentmemory.env".path ];
    extraOptions = [ "--user=${uid}:${uid}" ];
    ports = [ httpPort ];
  };
in
{
  my.ociImages.agentmemory = {
    kind = "nix";
    container = "agentmemory";
    image = "${agentmemory.image.imageName}:${agentmemory.image.imageTag}";
    imageFile = agentmemory.image;
  };

  my.configArtifacts."mcp/agentmemory/config" = {
    format = "yaml";
    source = agentmemoryConfig;
  };

  sops.secrets."opencode/go_api_key" = { };

  # LLM は OpenCode Go の OpenAI 互換 endpoint
  sops.templates."agentmemory.env" = {
    mode = "0400";
    restartUnits = [ "docker-agentmemory.service" ];
    content = ''
      OPENAI_API_KEY=${config.sops.placeholder."opencode/go_api_key"}
      OPENAI_BASE_URL=https://opencode.ai/zen/go/v1
      OPENAI_MODEL=minimax-m2.7
      EMBEDDING_PROVIDER=none
    '';
  };
  systemd.tmpfiles.settings."agentmemory" = {
    "/var/lib/agentmemory/data".d = {
      user = uid;
      group = uid;
      mode = "0755";
    };
  };

  virtualisation.oci-containers.containers = backend.containers;
  systemd.services = backend.systemdServices;

  # lifecycle hooks は各 CLI 設定から /run/current-system/sw/bin の stable 名で参照
  environment.systemPackages = [ agentmemory.hooks ];

  # opencode は plugins dir の自動ロードのみ、設定エントリ不要
  home-manager.users.${config.my.username} = _: {
    home.file.".config/opencode/plugins/agentmemory-capture.ts".source = agentmemory.opencodePlugin;
  };

  my.mcp.gatewayWaitUnits = [ "docker-agentmemory.service" ];
  my.mcp.targets.memory.transport.stdio.command = lib.getExe agentmemory.front;
  my.doctor = {
    units = backend.doctorUnits;
    managedFiles.agentmemory-opencode-capture = {
      path = "${config.my.homeDir}/.config/opencode/plugins/agentmemory-capture.ts";
      source = agentmemory.opencodePlugin;
    };
  };
}
