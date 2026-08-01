{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  agentgateway = pkgs.callPackage ./package.nix { };
  artifactSource = id: hostConfig.my.artifacts.${id}.source;

  # cargo test は filter が 0 件でも成功する。patch 側で test 名が変わると
  # package の build は緑のまま「何も実行しない check」になる
  lifecyclePatch = builtins.readFile ./package/mcp-downstream-lifecycle.patch;
  filter = builtins.head agentgateway.checkFlags;
  definedTests = builtins.filter (match: match != null) (
    map (line: builtins.match "\\+[[:space:]]*(async )?fn (${filter}[a-z_]+)\\(.*" line) (
      lib.splitString "\n" lifecyclePatch
    )
  );
in
{
  # 生成した artifact が gateway と backend の実配備先へそのまま渡ることを検査する
  gateway-artifact-contract =
    assert lib.all (
      endpoint:
      hostConfig.environment.etc."${endpoint.runtimeDirectory}/config.yaml".source
      == artifactSource endpoint.artifact
    ) (builtins.attrValues hostConfig.my.contract.mcp.endpoints);
    # soft 上限の暫定封じ込め、session 解放の代替にはしない
    assert lib.all (
      endpoint: hostConfig.systemd.services."${endpoint.service}".serviceConfig.LimitNOFILE == "4096:4096"
    ) (builtins.attrValues hostConfig.my.contract.mcp.endpoints);
    pkgs.runCommandLocal "check-gateway-artifact-contract" { nativeBuildInputs = [ pkgs.yq-go ]; } (
      lib.concatMapStrings (endpoint: ''
        test "$(yq -r '.config.mcp.sessionTtl' ${endpoint.source})" = 30m
        test "$(yq -r '.binds[0].port' ${endpoint.source})" = ${toString endpoint.port}
      '') (builtins.attrValues hostConfig.my.contract.mcp.endpoints)
      + "touch $out"
    );

  # 配備する package そのものを build し、同梱の downstream lifecycle test を実行する
  agentgateway-session-lifecycle =
    assert builtins.length definedTests == 3;
    assert lib.all (
      endpoint:
      hostConfig.systemd.services."${endpoint.service}".serviceConfig.ExecStart
      == "${agentgateway}/bin/agentgateway -f ${endpoint.source}"
    ) (builtins.attrValues hostConfig.my.contract.mcp.endpoints);
    agentgateway;
}
