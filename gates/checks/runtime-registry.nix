{
  helpers,
  pkgs,
  lib,
  self,
  hostConfig,
  hostOptions,
  ...
}:

{
  runtime-identity =
    let
      expected = builtins.fromJSON (builtins.readFile ../fixtures/runtime-identities.json);
      containers = hostConfig.virtualisation.oci-containers.containers;
      containerValues = builtins.attrValues containers;
      gatewayEndpoint = hostConfig.dotfiles.mcp.gateway;

      containerNetworks = lib.unique (
        lib.sort builtins.lessThan (
          map (lib.removePrefix "--network=") (
            lib.concatMap (
              container: builtins.filter (lib.hasPrefix "--network=") container.extraOptions
            ) containerValues
          )
        )
      );

      agentmemoryPersistentMounts = builtins.filter (
        volume:
        let
          segments = lib.splitString ":" volume;
        in
        builtins.length segments >= 2
        && lib.hasPrefix "/var/lib/" (lib.head segments)
        && builtins.elemAt segments 1 == "/data"
      ) containers.agentmemory.volumes;

      actual =
        assert lib.assertMsg (
          builtins.length containerNetworks == 1
        ) "runtime identity requires one container network: actual=${builtins.toJSON containerNetworks}";
        assert lib.assertMsg (builtins.length agentmemoryPersistentMounts == 1)
          "runtime identity requires one agentmemory persistent mount: actual=${builtins.toJSON agentmemoryPersistentMounts}";
        {
          mcpTargets = lib.mapAttrs (_: target: target.port) hostConfig.dotfiles.mcp.targets;
          gateway = {
            inherit (gatewayEndpoint) id port service;
          };
          containers = lib.sort builtins.lessThan (builtins.attrNames containers);
          containerNetwork = lib.head containerNetworks;
          secrets = lib.sort builtins.lessThan (builtins.attrNames hostConfig.sops.secrets);
          agentmemoryPersistentMount = lib.head agentmemoryPersistentMounts;
        };
      identityMatches = candidate: candidate == expected;
      missingTargetMutation = actual // {
        mcpTargets = builtins.removeAttrs actual.mcpTargets [ "memory" ];
      };
      commandNames = builtins.attrNames hostConfig.dotfiles.commands;
      serviceNames = builtins.attrNames hostConfig.systemd.services;
      timerNames = builtins.attrNames hostConfig.systemd.timers;
      installerExecutable = builtins.baseNameOf (lib.getExe hostConfig.dotfiles.commands.installAgents);
      legacyInstallerKey = "install" + "Clis";
      updaterName = "dotfiles-agent-autoupdate";
      legacyUpdaterName = "dotfiles-" + "cli-autoupdate";
      updaterNamesValid =
        services: timers:
        builtins.elem updaterName services
        && builtins.elem updaterName timers
        && !builtins.elem legacyUpdaterName services
        && !builtins.elem legacyUpdaterName timers;
    in
    assert lib.assertMsg (identityMatches actual) (
      "runtime identity mismatch: expected=${builtins.toJSON expected} "
      + "actual=${builtins.toJSON actual}"
    );
    assert lib.assertMsg (
      !identityMatches missingTargetMutation
    ) "runtime identity fixture accepted a deleted MCP target";
    assert installerExecutable == "dotfiles-install-agents";
    assert builtins.elem "installAgents" commandNames;
    assert !builtins.elem legacyInstallerKey commandNames;
    assert updaterNamesValid serviceNames timerNames;
    assert updaterNamesValid serviceNames (builtins.filter (timer: timer == updaterName) timerNames);
    assert !updaterNamesValid serviceNames (builtins.filter (timer: timer != updaterName) timerNames);
    pkgs.runCommandLocal "check-runtime-identity" { } "touch $out";

  # 全登録簿に共通する保険。各 owner の check も、自分が検査する集合の非空を
  # 独立して要求する
  registries-non-empty =
    let
      walk =
        path: opts:
        lib.concatLists (
          lib.mapAttrsToList (
            name: value:
            let
              here = path ++ [ name ];
            in
            if !(lib.isAttrs value) then
              [ ]
            else if value ? _type && value._type == "option" then
              lib.optional (
                lib.hasPrefix "attribute set of" (value.type.description or "")
                && lib.attrByPath here { } hostConfig == { }
              ) (lib.concatStringsSep "." here)
            else
              walk here value
          ) opts
        );

      empty = walk [ "dotfiles" ] hostOptions.dotfiles;
      unexpectedEmpty = builtins.filter (path: path != "dotfiles.observations") empty;
    in
    assert unexpectedEmpty == [ ];
    pkgs.runCommandLocal "check-registries-non-empty" { } "touch $out";

  # unit の層の file 名。ここが唯一の定義で、検査はここを読む
  # loopback port の占有は host 全体の資源で、単一 unit の不変条件ではない。
  # 宣言を増やさず、既存の contract と container 宣言から全 listener を集める
  # port を宣言しない生 unit は他のどの check にも届かない。socat 一本で
  # gateway と同じ port を 0.0.0.0 で取れる。unit を登録制にする
  service-listener-registry =
    let
      mcp = hostConfig.dotfiles.mcp;
      telemetry = hostConfig.dotfiles.telemetry;

      declaredHere = lib.unique (
        lib.concatMap (
          definition:
          lib.optionals (lib.hasPrefix (toString self) (toString definition.file)) (
            builtins.attrNames definition.value
          )
        ) hostOptions.systemd.services.definitionsWithLocations
      );

      # port を持たないと宣言した unit。増えるときは必ずこの表に現れる
      withoutListener = [
        "dotfiles-agent-autoupdate"
        "dotfiles-agent-project-cache-gc"
        "dotfiles-agent-resource-reaper"
        "dotfiles-zram-swap"
        "docker-build-artifact-gc"
        "docker-dotfiles-backends-network"
        "fstrim"
        "nix-daemon"
        "sonarqube-provision"
      ];

      registered = lib.sort builtins.lessThan (
        lib.unique (
          map (front: front.service) (builtins.attrValues mcp.fronts)
          ++ [ mcp.gateway.service ]
          ++ [ telemetry.service ]
          ++ map (name: "docker-${name}") (
            builtins.attrNames hostConfig.virtualisation.oci-containers.containers
          )
          ++ withoutListener
        )
      );
    in
    assert lib.assertMsg (lib.sort builtins.lessThan declaredHere == registered) (
      "systemd service is not registered as a listener or as portless: "
      + lib.concatStringsSep " " (
        lib.subtractLists registered declaredHere ++ lib.subtractLists declaredHere registered
      )
    );
    pkgs.runCommandLocal "check-service-listener-registry" { } "touch $out";

  loopback-port-single-owner =
    let
      mcp = hostConfig.dotfiles.mcp;
      telemetry = hostConfig.dotfiles.telemetry;
      inherit (helpers.containerArgv)
        publishedPorts
        ;

      listeners =
        lib.mapAttrsToList (name: front: {
          owner = "mcp-front-${name}";
          inherit (front) port;
        }) mcp.fronts
        ++ [
          {
            owner = mcp.gateway.service;
            inherit (mcp.gateway) port;
          }
          {
            owner = mcp.gateway.service;
            port = 15000;
          }
          {
            owner = mcp.gateway.service;
            port = 15020;
          }
          {
            owner = mcp.gateway.service;
            port = 15021;
          }
        ]
        ++ lib.mapAttrsToList (_: port: {
          owner = telemetry.service;
          inherit port;
        }) telemetry.ports
        ++ map (entry: {
          inherit (entry) owner;
          port = lib.toInt (builtins.elemAt (lib.splitString ":" entry.value) 1);
        }) publishedPorts;

      # owner を unique にしてから数えると、同じ owner が同じ port を二度
      # bind する形を見逃す。listener の数で判定する
      listenersOn = port: lib.filter (listener: listener.port == port) listeners;
      numbers = lib.unique (map (listener: listener.port) listeners);
      duplicates = lib.filter (port: builtins.length (listenersOn port) > 1) numbers;
    in
    assert listeners != [ ];
    assert lib.assertMsg (duplicates == [ ]) (
      "loopback port is bound by more than one owner: "
      + lib.concatMapStringsSep ", " (
        port:
        "${toString port} <- "
        + lib.concatStringsSep " " (map (listener: listener.owner) (listenersOn port))
      ) duplicates
    );
    pkgs.runCommandLocal "check-loopback-port-single-owner" { } "touch $out";

}
