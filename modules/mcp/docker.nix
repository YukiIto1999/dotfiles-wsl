{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.my;
in
{
  # backend container を network 接続・loopback publish・依存整形・unit 命名込みで宣言する helper、servers/*.nix へ _module.args 経由で配る
  _module.args.mkMcpBackend =
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

  users.users.${cfg.username}.extraGroups = [ "docker" ];

  virtualisation = {
    docker.enable = true;
    oci-containers.backend = "docker";
  };

  systemd.services.docker-mcp-backends-network = {
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

  my.doctor.units = {
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
