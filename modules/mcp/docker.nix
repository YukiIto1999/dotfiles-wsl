{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.my;
  imageDefinitions = builtins.attrValues cfg.ociImages;
  configuredContainers = config.virtualisation.oci-containers.containers;
in
{
  config = {
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

    users.users.${cfg.username}.extraGroups = [ "docker" ];

    virtualisation = {
      docker.enable = true;
      oci-containers.backend = "docker";
    };

    assertions = [
      {
        assertion =
          builtins.length (map (image: image.container) imageDefinitions)
          == builtins.length (lib.unique (map (image: image.container) imageDefinitions));
        message = "my.ociImages must map one image id to one unique container";
      }
      {
        assertion = lib.all (
          image:
          builtins.hasAttr image.container configuredContainers
          && configuredContainers.${image.container}.image == image.image
          && (configuredContainers.${image.container}.imageFile or null) == image.imageFile
          && configuredContainers.${image.container}.pull == "never"
        ) imageDefinitions;
        message = "my.ociImages must match an OCI container with the declared image, imageFile, and pull=never";
      }
      {
        assertion =
          lib.sort builtins.lessThan (map (image: image.container) imageDefinitions)
          == lib.sort builtins.lessThan (builtins.attrNames configuredContainers);
        message = "my.ociImages must cover every deployed OCI container exactly once";
      }
      {
        assertion = lib.all (
          image:
          if image.kind == "upstream" then
            image.repository != null
            && image.repository != ""
            && image.digest != null
            && builtins.match "^sha256:[0-9a-f]{64}$" image.digest != null
            && (
              let
                parts = lib.splitString "@" image.image;
                reference = builtins.elemAt parts 0;
              in
              builtins.length parts == 2
              && builtins.elemAt parts 1 == image.digest
              && (
                reference == image.repository
                || (
                  lib.hasPrefix "${image.repository}:" reference
                  &&
                    builtins.match "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$" (
                      lib.removePrefix "${image.repository}:" reference
                    ) != null
                )
              )
            )
            && image.imageFile == null
          else
            image.repository == null && image.digest == null && image.imageFile != null
        ) imageDefinitions;
        message = "my.ociImages must use digest-locked upstream images or Nix imageFile sources";
      }
    ];

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
  };
}
