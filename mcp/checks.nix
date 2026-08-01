{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  artifactSource = id: hostConfig.my.artifacts.${id}.source;
  containers = hostConfig.virtualisation.oci-containers.containers;
in
{
  # 生成した artifact が gateway と backend の実配備先へそのまま渡ることを検査する
  mcp-artifact-contract =
    assert lib.all (
      endpoint:
      hostConfig.environment.etc."${endpoint.runtimeDirectory}/config.yaml".source
      == artifactSource endpoint.artifact
    ) (builtins.attrValues hostConfig.my.contract.mcp.endpoints);
    assert lib.elem "${artifactSource "mcp/agentmemory/config"}:/app/config.yaml:ro"
      containers.agentmemory.volumes;
    assert
      hostConfig.sops.templates."searxng-settings.yml".content
      == builtins.readFile (artifactSource "mcp/searxng/settings-template");
    # soft 上限の暫定封じ込め、session 解放の代替にはしない
    assert lib.all (
      endpoint: hostConfig.systemd.services."${endpoint.service}".serviceConfig.LimitNOFILE == "4096:4096"
    ) (builtins.attrValues hostConfig.my.contract.mcp.endpoints);
    pkgs.runCommandLocal "check-mcp-artifact-contract" { nativeBuildInputs = [ pkgs.yq-go ]; } (
      lib.concatMapStrings (endpoint: ''
        test "$(yq -r '.config.mcp.sessionTtl' ${endpoint.source})" = 30m
        test "$(yq -r '.binds[0].port' ${endpoint.source})" = ${toString endpoint.port}
      '') (builtins.attrValues hostConfig.my.contract.mcp.endpoints)
      + "touch $out"
    );
}
