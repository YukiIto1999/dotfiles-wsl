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
  # gateway は front へ接続するだけで子 process を作らない
  gateway-front-contract =
    assert lib.all (front: front.url == "http://127.0.0.1:${toString front.port}/mcp") (
      builtins.attrValues hostConfig.my.contract.mcp.fronts
    );
    assert lib.all (front: hostConfig.systemd.services ? "${front.service}") (
      builtins.attrValues hostConfig.my.contract.mcp.fronts
    );
    pkgs.runCommandLocal "check-gateway-front-contract" { nativeBuildInputs = [ pkgs.yq-go ]; } (
      lib.concatMapStrings (endpoint: ''
        yq -r '[.binds[].listeners[].routes[].backends[].mcp.targets[] | .name + " " + .mcp.host] | sort | .[]' \
          ${endpoint.source} > actual-targets
        printf '%s' ${
          lib.escapeShellArg (
            lib.concatStringsSep "\n" (
              lib.sort builtins.lessThan (
                lib.mapAttrsToList (name: front: "${name} ${front.url}") hostConfig.my.contract.mcp.fronts
              )
            )
          )
        } > expected-targets
        printf '\n' >> expected-targets
        diff --unified expected-targets actual-targets
        test "$(yq -r '.binds[].listeners[].routes[].backends[].mcp.targets[] | select(.stdio) | length' ${endpoint.source} | wc -l)" = 0
      '') (builtins.attrValues hostConfig.my.contract.mcp.endpoints)
      + "touch $out"
    );

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
    # upstream は wildcard へ bind するので、通信の側で loopback へ限る
    assert lib.all (
      endpoint:
      hostConfig.systemd.services."${endpoint.service}".serviceConfig.IPAddressDeny == "any"
      && hostConfig.systemd.services."${endpoint.service}".serviceConfig.IPAddressAllow == "localhost"
    ) (builtins.attrValues hostConfig.my.contract.mcp.endpoints);
    pkgs.runCommandLocal "check-gateway-artifact-contract" { nativeBuildInputs = [ pkgs.yq-go ]; } (
      # schema の妥当性は読みではなく agentgateway 自身に判定させる
      lib.concatMapStrings (endpoint: ''
        ${agentgateway}/bin/agentgateway --validate-only -f ${endpoint.source}
      '') (builtins.attrValues hostConfig.my.contract.mcp.endpoints)
      + lib.concatMapStrings (endpoint: ''
        test "$(yq -r '.config.mcp.sessionTtl' ${endpoint.source})" = 30m
        test "$(yq -r '.config.adminAddr' ${endpoint.source})" = 127.0.0.1:${toString endpoint.managementPorts.admin}
        test "$(yq -r '.config.statsAddr' ${endpoint.source})" = 127.0.0.1:${toString endpoint.managementPorts.stats}
        test "$(yq -r '.config.readinessAddr' ${endpoint.source})" = 127.0.0.1:${toString endpoint.managementPorts.readiness}
        yq -r '.binds[].port' ${endpoint.source} | sort > actual-binds
        printf '%s\n' ${toString endpoint.port} | sort > expected-binds
        diff -u expected-binds actual-binds
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
