{
  config,
  pkgs,
  lib,
  ...
}:

let
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
          options.environment = lib.mkOption {
            type = lib.types.functionTo (lib.types.attrsOf lib.types.str);
            default = _: { };
            description = "この target が gateway process に要求する環境変数。endpoint の契約を受け取る。";
          };

          options.endpoint = lib.mkOption {
            type = lib.types.str;
            default = "default";
            description = "この target を畳み込む gateway endpoint の id。";
          };

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

  };

}
