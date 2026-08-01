{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  artifactSource = id: hostConfig.my.configArtifacts.${id}.source;
  containers = hostConfig.virtualisation.oci-containers.containers;
in
{
  # 生成した artifact が gateway と backend の実配備先へそのまま渡ることを検査する
  mcp-artifact-contract =
    assert
      hostConfig.environment.etc."agentgateway/config.yaml".source
      == artifactSource "mcp/agentgateway/config";
    assert lib.elem "${artifactSource "mcp/agentmemory/config"}:/app/config.yaml:ro"
      containers.agentmemory.volumes;
    assert
      hostConfig.sops.templates."searxng-settings.yml".content
      == builtins.readFile (artifactSource "mcp/searxng/settings-template");
    # soft 上限の暫定封じ込め、session 解放の代替にはしない
    assert hostConfig.systemd.services.agentgateway.serviceConfig.LimitNOFILE == "4096:4096";
    pkgs.runCommandLocal "check-mcp-artifact-contract" { } "touch $out";
}
