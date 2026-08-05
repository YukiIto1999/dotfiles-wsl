{
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  variantConfig,
  ...
}:

let
  agentgateway = pkgs.callPackage ./package.nix { };
  artifact = hostConfig.dotfiles.artifacts."mcp/gateway/default/config";
  expected = builtins.fromJSON (builtins.readFile ./fixtures/contract.json);
  gateway = hostConfig.dotfiles.mcp.gateway;
  fronts = hostConfig.dotfiles.mcp.fronts;
  service = hostConfig.systemd.services.${gateway.service};
  inherit (service) serviceConfig;
  frontServices = map (front: front.service) (builtins.attrValues fronts);
  deployedConfig = hostConfig.environment.etc."${gateway.runtimeDirectory}/config.yaml";
  sourceArtifacts = builtins.filter (entry: entry.source == gateway.source) (
    builtins.attrValues hostConfig.dotfiles.artifacts
  );
  variantGateway = variantConfig.dotfiles.mcp.gateway;
  variantArtifact = variantConfig.dotfiles.artifacts."mcp/gateway/default/config";
  variantDeployedConfig =
    variantConfig.environment.etc."${variantGateway.runtimeDirectory}/config.yaml";
  expectedVariant = expected // {
    port = 9876;
    url = "http://127.0.0.1:9876/mcp";
  };

  dependencyFree =
    candidate:
    lib.all (dependencies: lib.intersectLists frontServices dependencies == [ ]) [
      candidate.after
      candidate.requires
      candidate.wants
    ];
  firstFrontService = builtins.head frontServices;
  dependencyMutations = [
    (service // { after = service.after ++ [ firstFrontService ]; })
    (service // { requires = [ firstFrontService ]; })
    (service // { wants = [ firstFrontService ]; })
  ];

  lifecyclePatch = builtins.readFile ./package/mcp-downstream-lifecycle.patch;
  filter = builtins.head agentgateway.checkFlags;
  definedTests = builtins.filter (match: match != null) (
    map (line: builtins.match "\\+[[:space:]]*(async )?fn (${filter}[a-z_]+)\\(.*" line) (
      lib.splitString "\n" lifecyclePatch
    )
  );
in
{
  gateway-front-contract =
    assert fronts != { };
    assert gateway.targets == expected.targets;
    assert gateway.targets == builtins.attrNames fronts;
    assert lib.all (front: front.url == "http://127.0.0.1:${toString front.port}/mcp") (
      builtins.attrValues fronts
    );
    assert lib.all (front: hostConfig.systemd.services ? ${front.service}) (builtins.attrValues fronts);
    assert dependencyFree service;
    assert lib.all (candidate: !(dependencyFree candidate)) dependencyMutations;
    pkgs.runCommandLocal "check-gateway-front-contract" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      set -euo pipefail

      yq -r '[.binds[].listeners[].routes[].backends[].mcp.targets[] | .name + " " + .mcp.host] | sort | .[]' \
        ${gateway.source} > actual-targets
      printf '%s' ${
        lib.escapeShellArg (
          lib.concatStringsSep "\n" (
            lib.sort builtins.lessThan (lib.mapAttrsToList (name: front: "${name} ${front.url}") fronts)
          )
        )
      } > expected-targets
      printf '\n' >> expected-targets
      diff --unified expected-targets actual-targets
      test "$(yq -r '[.binds[].listeners[].routes[].backends[].mcp.targets[] | select(.stdio)] | length' ${gateway.source})" = 0
      touch $out
    '';

  gateway-artifact-contract =
    let
      projection = {
        inherit (gateway)
          id
          port
          runtimeDirectory
          service
          targets
          url
          ;
      };
    in
    assert expected.targets != [ ];
    assert
      builtins.attrNames gateway == [
        "id"
        "port"
        "runtimeDirectory"
        "service"
        "source"
        "targets"
        "url"
      ];
    assert hostOptions.dotfiles.mcp.gateway.id.readOnly;
    assert !(hostOptions.dotfiles.mcp.gateway.port.readOnly or false);
    assert hostOptions.dotfiles.mcp.gateway.url.readOnly;
    assert hostOptions.dotfiles.mcp.gateway.service.readOnly;
    assert hostOptions.dotfiles.mcp.gateway.runtimeDirectory.readOnly;
    assert hostOptions.dotfiles.mcp.gateway.source.readOnly;
    assert hostOptions.dotfiles.mcp.gateway.source.type.name == "path";
    assert hostOptions.dotfiles.mcp.gateway.targets.readOnly;
    assert projection == expected;
    assert
      {
        inherit (variantGateway)
          id
          port
          runtimeDirectory
          service
          targets
          url
          ;
      } == expectedVariant;
    assert artifact.format == "yaml";
    assert artifact.deployedAt == "/etc/agentgateway-default/config.yaml";
    assert artifact.source == gateway.source;
    assert deployedConfig.source == gateway.source;
    assert builtins.length sourceArtifacts == 1;
    assert variantGateway.source != gateway.source;
    assert variantArtifact.source == variantGateway.source;
    assert variantArtifact.deployedAt == "/etc/agentgateway-default/config.yaml";
    assert variantDeployedConfig.source == variantGateway.source;
    assert service.after == [ "network.target" ];
    assert service.requires == [ ];
    assert service.wants == [ ];
    assert serviceConfig.User == hostConfig.dotfiles.host.username;
    assert serviceConfig.Environment == [ "HOME=${hostConfig.dotfiles.host.homeDir}" ];
    assert serviceConfig.RuntimeDirectory == gateway.runtimeDirectory;
    assert serviceConfig.RuntimeDirectoryMode == "0700";
    assert serviceConfig.LimitNOFILE == "4096:4096";
    assert serviceConfig.MemoryMax == "2G";
    assert serviceConfig.IPAddressDeny == "any";
    assert serviceConfig.IPAddressAllow == "localhost";
    assert serviceConfig.Restart == "always";
    assert serviceConfig.RestartSec == "5s";
    pkgs.runCommandLocal "check-gateway-artifact-contract" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      set -euo pipefail

        ${agentgateway}/bin/agentgateway --validate-only -f ${gateway.source}
        ${agentgateway}/bin/agentgateway --validate-only -f ${variantGateway.source}
      test "$(yq -r '.config.mcp.sessionTtl' ${gateway.source})" = 30m
      test "$(yq -r '.config.adminAddr' ${gateway.source})" = 127.0.0.1:15000
      test "$(yq -r '.config.statsAddr' ${gateway.source})" = 127.0.0.1:15020
      test "$(yq -r '.config.readinessAddr' ${gateway.source})" = 127.0.0.1:15021
        test "$(yq -r '.binds | length' ${gateway.source})" = 1
        test "$(yq -r '.binds[0].port' ${gateway.source})" = ${toString gateway.port}
        test "$(yq -r '.binds[0].port' ${variantGateway.source})" = ${toString variantGateway.port}
      test "$(yq -r '.binds[0].listeners | length' ${gateway.source})" = 1
      test "$(yq -r '.binds[0].listeners[0].routes[0].backends | length' ${gateway.source})" = 1
      test "$(yq -r '.binds[0].listeners[0].routes[0].backends[0].mcp.failureMode' ${gateway.source})" = failOpen
      test "$(yq -r '.binds[0].listeners[0].routes[0].policies.mcpAuthorization.rules | length' ${gateway.source})" = 1
      test "$(yq -r '.binds[0].listeners[0].routes[0].policies.mcpAuthorization.rules[0].deny' ${gateway.source})" = 'mcp.tool.name == "web_url_read"'
      touch $out
    '';

  agentgateway-session-lifecycle =
    assert builtins.length definedTests == 3;
    assert serviceConfig.ExecStart == "${agentgateway}/bin/agentgateway -f ${gateway.source}";
    agentgateway;
}
