{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles.mcp;
  frontCommand = pkgs.callPackage ./package/front-command.nix { };
  targetNames = builtins.attrNames cfg.targets;
  isExecutable = value: builtins.match "/[^[:space:]]+" value != null;
  invalidExecutables = builtins.filter (
    name: !isExecutable cfg.targets.${name}.executable
  ) targetNames;
  invalidStreamableLifecycles = builtins.filter (
    name:
    cfg.targets.${name}.serverTransport == "streamable-http"
    && cfg.targets.${name}.serverLifecycle != "service"
  ) targetNames;
  observationTimeoutSeconds = 10;
  restartWarningCount = 5;
  restartFailureCount = 20;

  fronts = lib.mapAttrs (name: target: {
    inherit name;
    inherit (target) port;
    service = "mcp-front-${name}";
    runtimeDirectory = "mcp-front-${name}";
    runtimeDirectoryPath = "/run/mcp-front-${name}";
    url = "http://127.0.0.1:${toString target.port}/mcp";
  }) cfg.targets;

  targetsWithDelimiter = builtins.filter (name: builtins.match ".*_.*" name != null) targetNames;
  prefixCollisions = builtins.filter (
    name: builtins.any (other: other != name && lib.hasPrefix name other) targetNames
  ) targetNames;
  ports = map (target: target.port) (builtins.attrValues cfg.targets);
  providedProviders = lib.unique (map (target: target.provider) (builtins.attrValues cfg.targets));
  observedServices = [
    cfg.gateway.service
  ]
  ++ map (front: front.service) (builtins.attrValues fronts);
  commonObservation = checkId: failureMessage: {
    inherit checkId failureMessage;
    resourceKey = null;
    timeoutSeconds = observationTimeoutSeconds;
  };
  serviceObservations = builtins.listToAttrs (
    map (
      service:
      let
        unit = "${service}.service";
      in
      lib.nameValuePair "mcp/service/${service}" (
        commonObservation "service/${service}" "${unit} is not operational"
        // {
          kind = "systemd-service";
          inherit unit;
          loadStates = [ "loaded" ];
          activeStates = [ "active" ];
          results = [ "success" ];
        }
      )
    ) observedServices
  );
  serviceRestartObservations = builtins.listToAttrs (
    map (
      service:
      let
        unit = "${service}.service";
      in
      lib.nameValuePair "mcp/service-restart/${service}" (
        commonObservation "restart/service/${service}" "could not observe restart count for ${unit}"
        // {
          kind = "restart-counter";
          sourceKind = "systemd-service";
          target = unit;
          warningAt = restartWarningCount;
          failureAt = restartFailureCount;
        }
      )
    ) observedServices
  );
in
{
  options.dotfiles.mcp = {
    enabledProviders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "host が必要とする mcp/<provider> unit ID の重複しない一覧";
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            provider = lib.mkOption {
              type = lib.types.str;
              description = "target の責務を所有する mcp/<provider> unit ID";
            };
            executable = lib.mkOption {
              type = lib.types.addCheck lib.types.str isExecutable;
              description = "front が引数なしで起動する MCP server の絶対 path";
            };
            serverTransport = lib.mkOption {
              type = lib.types.enum [
                "stdio"
                "streamable-http"
              ];
              default = "stdio";
              description = "front が executable を公開する前に変換する transport";
            };
            serverLifecycle = lib.mkOption {
              type = lib.types.enum [
                "service"
                "session"
              ];
              description = "server process を front service または downstream session のどちらが所有するか";
            };
            port = lib.mkOption {
              type = lib.types.ints.between 8770 8789;
              description = "front が loopback で待ち受ける一意な port";
            };
            needsNetwork = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "true が loopback 外への接続を許可する front の通信要件";
            };
            waitUnits = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "front の起動と存続に必要な backend unit の一覧";
            };
            probe = lib.mkOption {
              readOnly = true;
              type = lib.types.submodule {
                options = {
                  tool = lib.mkOption {
                    type = lib.types.str;
                    description = "target の生存確認と契約照合に使う副作用のない tool 名";
                  };
                  args = lib.mkOption {
                    type = lib.types.attrsOf lib.types.anything;
                    description = "tool の契約照合に使う JSON 引数";
                  };
                  timeout = lib.mkOption {
                    type = lib.types.ints.between 1 120;
                    description = "失敗判定まで許容する probe の最大待機秒数";
                  };
                };
              };
              description = "doctor による target の tool 契約照合に使う読み取り専用 probe";
            };
          };
        }
      );
      default = { };
      internal = true;
      description = "公開 gateway が束ねる MCP target の実行契約";
    };

    fronts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "target と front を対応付ける識別子";
            };
            port = lib.mkOption {
              type = lib.types.port;
              description = "対応する target から継承する loopback 待ち受け port";
            };
            url = lib.mkOption {
              type = lib.types.str;
              description = "公開 gateway が接続する front の MCP endpoint URL";
            };
            service = lib.mkOption {
              type = lib.types.str;
              description = "front の process と再起動を所有する systemd service 名";
            };
            runtimeDirectory = lib.mkOption {
              type = lib.types.str;
              description = "systemd が所有する front の実行時 directory 名";
            };
            runtimeDirectoryPath = lib.mkOption {
              type = lib.types.str;
              description = "front に許可する実行時書き込み領域の絶対 path";
            };
          };
        }
      );
      readOnly = true;
      internal = true;
      description = "target の実行契約から一意に導く Streamable HTTP front の接続契約";
    };

    sessionPolicy = lib.mkOption {
      readOnly = true;
      internal = true;
      type = lib.types.submodule {
        options = {
          idleSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            description = "公開 gateway が無通信 session を保持する秒数";
          };
          frontGraceSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            description = "session front の先行失効を防ぐ追加保持秒数";
          };
        };
      };
      description = "公開 gateway と session front が共有する MCP session の idle 契約";
    };

    chromium = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "browser target 間で実装と version を共有する Chromium package";
    };
  };

  config.dotfiles.mcp.fronts = fronts;
  config.dotfiles.mcp.sessionPolicy = {
    idleSeconds = 1800;
    # 公開 gateway と同じ TTL で起こりうる session front の先行失効回避
    frontGraceSeconds = 60;
  };
  config.dotfiles.mcp.chromium = pkgs.chromium;
  config.dotfiles.observations =
    serviceObservations
    // serviceRestartObservations
    // {
      "mcp/roster" = commonObservation "mcp-roster" "MCP target roster is empty" // {
        kind = "roster";
        members = targetNames;
        minimumCount = 1;
        failureOnly = true;
      };
    };

  config.systemd.services = lib.mapAttrs' (
    name: front:
    let
      target = cfg.targets.${name};
    in
    lib.nameValuePair front.service {
      description = "MCP front (${name})";
      after = [ "network.target" ] ++ target.waitUnits;
      requires = target.waitUnits;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = config.dotfiles.host.username;
        RuntimeDirectory = front.runtimeDirectory;
        RuntimeDirectoryMode = "0700";
        Environment = [ "HOME=${config.dotfiles.host.homeDir}" ];
        ExecStart =
          if target.serverTransport == "streamable-http" then
            target.executable
          else
            frontCommand {
              inherit (target) executable serverLifecycle;
              inherit (front) port;
              inherit (cfg) sessionPolicy;
            };
        MemoryMax = "2G";
      }
      // lib.optionalAttrs (!target.needsNetwork) {
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
      }
      // {
        Restart = "always";
        RestartSec = "5s";
      };
    }
  ) fronts;

  config.assertions = [
    {
      assertion = cfg.enabledProviders != [ ] && cfg.enabledProviders == lib.unique cfg.enabledProviders;
      message = "dotfiles.mcp.enabledProviders must be non-empty and unique";
    }
    {
      assertion =
        lib.sort builtins.lessThan cfg.enabledProviders == lib.sort builtins.lessThan providedProviders;
      message = "dotfiles.mcp.enabledProviders and target providers must match exactly";
    }
    {
      assertion = targetsWithDelimiter == [ ];
      message =
        "MCP target names must not contain '_': " + lib.concatStringsSep ", " targetsWithDelimiter;
    }
    {
      assertion = prefixCollisions == [ ];
      message = "MCP target name is a prefix of another: " + lib.concatStringsSep ", " prefixCollisions;
    }
    {
      assertion = ports == lib.unique ports;
      message = "MCP target ports must be unique";
    }
    {
      assertion = invalidExecutables == [ ];
      message = "MCP target executables must be absolute paths without arguments";
    }
    {
      assertion = invalidStreamableLifecycles == [ ];
      message = "Native Streamable HTTP MCP targets must use service lifecycle";
    }
  ];
}
