{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  agentgateway = pkgs.callPackage ./package.nix { };

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
