{ config, lib, ... }:

let
  cfg = config.my;
in
{
  options.my = {
    username = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "Primary login user and WSL default user.";
    };

    homeDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Primary user's home directory. Derived from username.";
    };

    dotfilesDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.homeDir}/dotfiles-wsl";
      description = "Absolute path to the dotfiles checkout that out-of-store symlinks and scripts reference.";
    };

    gatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 8765;
      description = "Loopback port the agentgateway MCP listener binds.";
    };

    gatewayUrl = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "MCP gateway URL every AI CLI points at. Derived from gatewayPort.";
    };

    accounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "account-1"
        "account-2"
      ];
      description = "GitHub account ids. Each maps to a sops secret pair, a gh host user and a github MCP target. The first entry is primary: gh's active user and the default token in hosts.yml.";
    };

    workIdentity = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "~/projects/business/";
      description = "gitdir glob that selects the work git identity. null disables it.";
    };

    sops.enrollmentState = lib.mkOption {
      type = lib.types.enum [
        "migration"
        "enrolled"
      ];
      description = "SOPS host identity migration state. Doctor derives the legacy home-key policy from this domain state.";
    };

    doctor = {
      schemaVersion = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        readOnly = true;
        internal = true;
        description = "dotfiles-doctor manifest の schema version。";
      };

      units = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.expected = lib.mkOption {
              type = lib.types.submodule {
                options = {
                  LoadState = lib.mkOption {
                    type = lib.types.str;
                    description = "systemd LoadState の期待値。";
                  };
                  ActiveState = lib.mkOption {
                    type = lib.types.str;
                    description = "systemd ActiveState の期待値。";
                  };
                  SubState = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "systemd SubState の期待値。null は検査しない。";
                  };
                  Result = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "systemd Result の期待値。null は検査しない。";
                  };
                };
              };
              description = "systemctl show で検査する property と期待値。";
            };
          }
        );
        default = { };
        internal = true;
        description = "dotfiles-doctor が検査する systemd unit。attribute key が安定 id。";
      };

      managedFiles = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                description = "current generation が管理する runtime file の絶対パス。";
              };
              source = lib.mkOption {
                type = lib.types.path;
                description = "runtime file と比較する immutable source。";
              };
            };
          }
        );
        default = { };
        internal = true;
        description = "dotfiles-doctor が current generation の source と比較する file。";
      };

      skillNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        internal = true;
        description = "各 CLI に配備されることを要求する skill 名。";
      };

      agentFiles = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        internal = true;
        description = "CLI ごとに配備を要求する agent file 名。";
      };

      wslInterop = lib.mkOption {
        type = lib.types.submodule {
          options = {
            launcherName = lib.mkOption { type = lib.types.str; };
            launcherPath = lib.mkOption { type = lib.types.str; };
            launcherSource = lib.mkOption { type = lib.types.path; };
            windowsCommand = lib.mkOption { type = lib.types.str; };
          };
        };
        internal = true;
        description = "WSL から Windows を起動する launcher と固定 command の検査契約。";
      };
    };
  };

  config.my = {
    homeDir = "/home/${cfg.username}";
    gatewayUrl = "http://localhost:${toString cfg.gatewayPort}/mcp";
  };
}
