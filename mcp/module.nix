{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles.mcp;
  targetNames = builtins.attrNames cfg.targets;

  # target が front の名前、URL、書き込み領域を一度だけ決める。
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
  githubTargets = builtins.attrNames (
    lib.filterAttrs (_: target: target.provider == "github") cfg.targets
  );
  expectedGithubTargets = lib.sort builtins.lessThan (
    map (account: "github-${account}") config.dotfiles.accounts
  );
in
{
  options.dotfiles.mcp = {
    enabledProviders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "この host が必要とする mcp/<provider> unit ID。";
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            provider = lib.mkOption {
              type = lib.types.str;
              description = "target を所有する mcp/<provider> unit ID。";
            };
            port = lib.mkOption {
              type = lib.types.ints.between 8770 8789;
              description = "front が loopback へ bind する port。";
            };
            serve = lib.mkOption {
              type = lib.types.functionTo lib.types.str;
              description = "port を受け取り、Streamable HTTP front の起動 command を返す関数。";
            };
            needsNetwork = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "front が loopback の外へ接続するか。";
            };
            waitUnits = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "front が起動前に必要とする backend unit。";
            };
            probe = lib.mkOption {
              readOnly = true;
              type = lib.types.submodule {
                options = {
                  tool = lib.mkOption { type = lib.types.str; };
                  args = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
                  timeout = lib.mkOption { type = lib.types.ints.positive; };
                };
              };
              description = "doctor が target の tool 名を照合するための読み取り専用 probe。";
            };
          };
        }
      );
      default = { };
      internal = true;
      description = "agentgateway が公開する MCP target。";
    };

    fronts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            port = lib.mkOption { type = lib.types.port; };
            url = lib.mkOption { type = lib.types.str; };
            service = lib.mkOption { type = lib.types.str; };
            runtimeDirectory = lib.mkOption { type = lib.types.str; };
            runtimeDirectoryPath = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      readOnly = true;
      internal = true;
      description = "target から導いた常駐 Streamable HTTP front。";
    };

    chromium = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "browser target が共有する Chromium package。";
    };
  };

  config.dotfiles.mcp.fronts = fronts;
  config.dotfiles.mcp.chromium = pkgs.chromium;

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
        ExecStart = target.serve front.port;
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
      assertion = githubTargets == expectedGithubTargets;
      message = "GitHub target IDs must match github-<account> exactly";
    }
  ];
}
