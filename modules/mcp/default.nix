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
          options.command = lib.mkOption {
            type = lib.types.str;
            description = "gateway が spawn する stdio front の起動コマンド絶対パス。";
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

  imports = [
    ./docker.nix
    ./gateway.nix
    ./servers/codex.nix
    ./servers/context7.nix
    ./servers/probe.nix
    ./servers/searxng.nix
    ./servers/crawl4ai.nix
    ./servers/memory.nix
    ./servers/playwright.nix
    ./servers/github.nix
  ];

  config.assertions = [
    {
      assertion = targetPrefixConflicts == [ ];
      message =
        "MCP target names must not prefix another target name with '<name>_': "
        + lib.concatStringsSep ", " targetPrefixConflicts;
    }
  ];

  config._module.args = {
    mkMcpServer = pkgs.callPackage ../../pkgs/mk-mcp-server.nix { };
    mkNpmMcp = pkgs.callPackage ../../pkgs/mk-npm-mcp.nix { };
  };
}
