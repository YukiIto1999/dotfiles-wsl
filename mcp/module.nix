{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.my;
  targetNames = builtins.attrNames cfg.mcp.targets;

  # front の名前と URL と書き込み領域は target 名と port から導く。二つ目の roster を作らない
  fronts = lib.mapAttrs (name: target: {
    inherit name;
    inherit (target) port;
    service = "mcp-front-${name}";
    runtimeDirectory = "mcp-front-${name}";
    runtimeDirectoryPath = "/run/mcp-front-${name}";
    url = "http://127.0.0.1:${toString target.port}/mcp";
  }) cfg.mcp.targets;

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
          options.port = lib.mkOption {
            type = lib.types.port;
            description = "この target の front が loopback へ bind する port。";
          };

          # front は常駐する。gateway は接続するだけで子 process を作らない
          options.serve = lib.mkOption {
            type = lib.types.functionTo lib.types.str;
            description = "port を受け取り、Streamable HTTP を話す front の起動 command を返す。";
          };

          options.waitUnits = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "front が起動前に待つ systemd unit。";
          };
        }
      );
      default = { };
      description = "agentgateway が畳み込む MCP target の集合。";
    };

  };

  # front と gateway の対応は名前から導ける。契約として公開する
  config.my.contract.mcp.fronts = fronts;

  # front は常駐し、downstream session ごとの複製を作らない
  config.systemd.services = lib.mapAttrs' (
    name: front:
    lib.nameValuePair front.service {
      description = "MCP front (${name})";
      after = [ "network.target" ] ++ cfg.mcp.targets.${name}.waitUnits;
      wants = cfg.mcp.targets.${name}.waitUnits;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = cfg.username;
        # front が生成物を置ける唯一の場所。service の停止で消える
        RuntimeDirectory = front.runtimeDirectory;
        RuntimeDirectoryMode = "0700";
        Environment = [ "HOME=${cfg.homeDir}" ];
        ExecStart = cfg.mcp.targets.${name}.serve front.port;
        # backend だけ上限を持ち front が持たないのは非対称。chromium を抱える
        # playwright が最も大きいので、そこに合わせて一律に置く
        MemoryMax = "2G";
        Restart = "always";
        RestartSec = "5s";
      };
    }
  ) fronts;

  config.my.doctor.units = lib.mapAttrs' (
    _: front:
    lib.nameValuePair "${front.service}.service" {
      expected = {
        LoadState = "loaded";
        ActiveState = "active";
        SubState = "running";
        Result = "success";
      };
    }
  ) fronts;

  config.assertions = [
    {
      assertion = targetPrefixConflicts == [ ];
      message =
        "MCP target names must not prefix another target name with '<name>_': "
        + lib.concatStringsSep ", " targetPrefixConflicts;
    }
  ];

  config._module.args = {
    # stdio しか話さない front を Streamable HTTP へ載せる共通の機構
    serveOverProxy =
      command: port:
      "${lib.getExe pkgs.mcp-proxy} --host 127.0.0.1 --port ${toString port} --stateless ${command}";

    mkMcpServer = pkgs.callPackage ./package/mk-server.nix { };
    mkNpmMcp = pkgs.callPackage ./package/mk-npm.nix { };

  };

}
