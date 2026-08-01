{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.my;
  targetNames = builtins.attrNames config.my.mcp.targets;
  targetPrefixConflicts = lib.concatMap (
    name:
    map (other: "${name} -> ${other}") (
      builtins.filter (other: other != name && lib.hasPrefix "${name}_" other) targetNames
    )
  ) targetNames;
in
{
  options.my.mcp = {
    # target は skills が参照する安定した公開契約、key が target 名
    targets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.transport = lib.mkOption {
            type = lib.types.attrTag {
              stdio = lib.mkOption {
                type = lib.types.submodule {
                  options.command = lib.mkOption {
                    type = lib.types.str;
                    description = "gateway が起動する子 process の絶対パス。";
                  };
                };
                description = "downstream session ごとに子 process が複製される経路。";
              };
              http = lib.mkOption {
                type = lib.types.submodule {
                  options.url = lib.mkOption {
                    type = lib.types.str;
                    description = "常駐 front の Streamable HTTP endpoint。";
                  };
                };
                description = "常駐 front を共有し、session ごとの複製が起きない経路。";
              };
            };
            description = "gateway が target へ接続する経路。stdio と http のどちらか一方だけを持つ。";
          };
        }
      );
      default = { };
      description = "agentgateway が畳み込む MCP target の集合。";
    };

    gatewayWaitUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "agentgateway が起動前に待つ backend systemd unit。";
    };
  };

  config.assertions = [
    {
      assertion = targetPrefixConflicts == [ ];
      message =
        "MCP target names must not prefix another target name with '<name>_': "
        + lib.concatStringsSep ", " targetPrefixConflicts;
    }
  ];

  config._module.args = {
    mkMcpServer = pkgs.callPackage ./package/mk-server.nix { };
    mkNpmMcp = pkgs.callPackage ./package/mk-npm.nix { };

    # backend container を network 接続・loopback publish・依存整形・unit 命名込みで宣言する helper、各 target の module へ _module.args 経由で配る
    mkMcpBackend =
      name:
      {
        image,
        imageFile ? null,
        volumes ? [ ],
        environmentFiles ? [ ],
        extraOptions ? [ ],
        ports ? [ ],
        deps ? [ ],
      }:
      let
        backendSystemdServices = {
          "docker-${name}" = {
            after = [ "docker-mcp-backends-network.service" ] ++ deps;
            requires = [ "docker-mcp-backends-network.service" ] ++ deps;
            serviceConfig = {
              Restart = lib.mkForce "always";
              RestartSec = "5s";
            };
          };
        };
      in
      {
        containers."${name}" = {
          inherit image;
          pull = "never";
        }
        // lib.optionalAttrs (imageFile != null) { inherit imageFile; }
        // lib.optionalAttrs (volumes != [ ]) { inherit volumes; }
        // lib.optionalAttrs (environmentFiles != [ ]) { inherit environmentFiles; }
        // {
          extraOptions = [
            "--network=mcp-backends"
          ]
          ++ extraOptions
          ++ lib.concatMap (port: [
            "-p"
            "127.0.0.1:${port}:${port}"
          ]) ports;
        };
        systemdServices = backendSystemdServices;
        doctorUnits = lib.mapAttrs' (
          unitName: _:
          lib.nameValuePair "${unitName}.service" {
            expected = {
              LoadState = "loaded";
              ActiveState = "active";
              SubState = "running";
              Result = "success";
            };
          }
        ) backendSystemdServices;
      };
  };

  config.users.users.${cfg.username}.extraGroups = [ "docker" ];

  config.virtualisation = {
    docker.enable = true;
    oci-containers.backend = "docker";
  };

  config.systemd.services.docker-mcp-backends-network = {
    description = "Docker network for MCP backing services";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.docker}/bin/docker network inspect mcp-backends >/dev/null 2>&1 \
        || ${pkgs.docker}/bin/docker network create mcp-backends
    '';
  };

  config.my.doctor.units = {
    "docker.service".expected = {
      LoadState = "loaded";
      ActiveState = "active";
      SubState = "running";
      Result = "success";
    };
    "docker-mcp-backends-network.service".expected = {
      LoadState = "loaded";
      ActiveState = "active";
      SubState = "exited";
      Result = "success";
    };
  };
}
