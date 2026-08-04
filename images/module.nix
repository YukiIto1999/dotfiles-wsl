{
  config,
  lib,
  pkgs,
  mkCommand,
  substituteCommandVars,
  ...
}:

let
  cfg = config.my;
  primitives = cfg.contract.primitives.libraries;
  imageDefinitions = builtins.attrValues cfg.images;
  configuredContainers = config.virtualisation.oci-containers.containers;

  ociImageManifestEntries = lib.mapAttrsToList (id: image: {
    inherit id;
    inherit (image)
      kind
      container
      image
      repository
      digest
      ;
    imageFile = if image.imageFile == null then null else toString image.imageFile;
  }) cfg.images;

  ociImageManifest = (pkgs.formats.json { }).generate "dotfiles-oci-images-v2.json" {
    schemaVersion = 2;
    images = ociImageManifestEntries;
  };

  mkNixImageIdentity =
    id: image:
    pkgs.runCommandLocal "dotfiles-oci-${id}-image-identity-v1.json"
      {
        nativeBuildInputs = with pkgs; [
          coreutils
          gnutar
          gzip
          jq
        ];
        inherit (image) imageFile;
        imageReference = image.image;
      }
      ''
        set -euo pipefail

        work_dir=$(mktemp -d)
        trap 'rm -rf -- "$work_dir"' EXIT
        manifest_json=$work_dir/manifest.json
        config_json=$work_dir/config.json

        tar --extract --to-stdout --file "$imageFile" manifest.json > "$manifest_json"
        jq --exit-status --slurp --arg reference "$imageReference" '
          length == 1 and
          (.[0] | type) == "array" and (.[0] | length) == 1 and
          (.[0][0].Config | type == "string" and test("^[0-9a-f]{64}\\.json$")) and
          .[0][0].RepoTags == [$reference] and
          (.[0][0].Layers | type) == "array" and (.[0][0].Layers | length) > 0 and
          all(.[0][0].Layers[];
            type == "string" and
            test("^([0-9a-f]{64}\\.tar|[0-9a-f]{64}/layer\\.tar)$")
          )
        ' "$manifest_json" > /dev/null

        config_member=$(jq --raw-output '.[0].Config' "$manifest_json")
        tar --extract --to-stdout --file "$imageFile" -- "$config_member" > "$config_json"
        jq --exit-status --slurp 'length == 1 and (.[0] | type) == "object"' \
          "$config_json" > /dev/null

        expected_hash=$(jq --raw-output '.[0].Config | rtrimstr(".json")' "$manifest_json")
        actual_hash=$(sha256sum -- "$config_json" | cut -d ' ' -f 1)
        test "$actual_hash" = "$expected_hash"

        jq --null-input \
          --arg imageReference "$imageReference" \
          --arg imageFile "$imageFile" \
          --arg imageId "sha256:$expected_hash" \
          '{
            schemaVersion: 1,
            imageReference: $imageReference,
            imageFile: $imageFile,
            imageId: $imageId
          }' > "$out"
      '';

  nixImageIdentityFiles = lib.mapAttrs mkNixImageIdentity (
    lib.filterAttrs (_: image: image.kind == "nix") cfg.images
  );

  doctorOciImageManifestEntries = map (
    image:
    image
    // {
      unit = "docker-${image.container}.service";
      expectedImageIdFile =
        if image.kind == "nix" then toString nixImageIdentityFiles.${image.id} else null;
    }
  ) ociImageManifestEntries;

  mkSyncImages =
    name:
    pkgs.writeShellApplication {
      inherit name;
      # active rebuild の判定に同じ full receipt validator を埋め込む。validator library 内の更新関数は呼ばない。
      excludeShellChecks = [ "SC2329" ];
      runtimeInputs = with pkgs; [
        coreutils
        git
        jq
        util-linux
      ];
      text = substituteCommandVars {
        atomicFileFunctions = builtins.readFile primitives.atomicFile;
        ociImageStateFunctions = builtins.readFile ./impl/lib/image-state.sh;

        dockerCommand = lib.escapeShellArg (lib.getExe pkgs.docker);
        ociImageSyncUser = cfg.username;
        ociImageManifest = lib.escapeShellArg ociImageManifest;
        ociImageStateRoot = lib.escapeShellArg "${cfg.homeDir}/.local/state/dotfiles-wsl/image-sync";
        imageSyncEnvironmentSetup = ''
          if [[ $(id -un) != "$expected_user" ]]; then
            die 2 "dotfiles-sync-images must run as $expected_user"
          fi
        '';
      } (builtins.readFile ./impl/sync-images.sh);
    };
  # 宣言へ固定する digest を registry から取る。sync は宣言済み digest しか見ない
  imageDigest = mkCommand {
    name = "dotfiles-image-digest";
    src = ./impl/image-digest.sh;
    runtimeInputs = with pkgs; [
      docker
      jq
    ];
  };

  syncImages = (mkSyncImages "dotfiles-sync-images").overrideAttrs (old: {
    passthru = (old.passthru or { }) // {
      manifest = ociImageManifest;
    };
  });
in
{
  # container を network 接続・loopback publish・依存整形・unit 命名込みで宣言する helper
  config._module.args.mkContainerBackend =
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
          after = [ "docker-dotfiles-backends-network.service" ] ++ deps;
          requires = [ "docker-dotfiles-backends-network.service" ] ++ deps;
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
          "--network=dotfiles-backends"
        ]
        ++ extraOptions
        ++ lib.concatMap (port: [
          "-p"
          "127.0.0.1:${port}:${port}"
        ]) ports;
      };
      systemdServices = backendSystemdServices;
    };

  options.my.images = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          kind = lib.mkOption {
            type = lib.types.enum [
              "nix"
              "upstream"
            ];
            description = "image の取得責任。nix は imageFile、upstream は明示 sync が所有する。";
          };
          container = lib.mkOption {
            type = lib.types.str;
            description = "virtualisation.oci-containers.containers の attribute 名。";
          };
          image = lib.mkOption {
            type = lib.types.str;
            description = "docker run が使う canonical image reference。";
          };
          repository = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "upstream RepoDigest の repository。";
          };
          digest = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "upstream image の sha256 digest。";
          };
          imageFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Nix が生成し、OCI module が load する image archive。";
          };
        };
      }
    );
    default = { };
    internal = true;
    description = "OCI runtime と明示 sync が共有する image inventory。";
  };

  config.my.commands = { inherit syncImages imageDigest; };

  # doctor が読む契約。images が所有する派生物を一箇所で公開する
  config.my.contract.images = {
    libraries = {
      imageState = ./impl/lib/image-state.sh;
      # 互換を保つと約束した旧版。rebuild の interop test が読む
      legacyImageState = ./fixtures/legacy-image-state.sh;
    };
    entries = doctorOciImageManifestEntries;
    identityFiles = nixImageIdentityFiles;
    syncStatusCommand = lib.getExe syncImages;
  };

  config.environment.etc."dotfiles/oci-images.json".source = ociImageManifest;

  config.users.users.${cfg.username}.extraGroups = [ "docker" ];

  config.virtualisation = {
    docker.enable = true;
    oci-containers.backend = "docker";
  };

  config.systemd.services.docker-dotfiles-backends-network = {
    description = "Docker network for backing services";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.docker}/bin/docker network inspect dotfiles-backends >/dev/null 2>&1 \
        || ${pkgs.docker}/bin/docker network create dotfiles-backends
    '';
  };

  # inventory と実際に配備される container の対応を型では表せないので assertion で閉じる
  config.assertions = [
    {
      assertion =
        builtins.length (map (image: image.container) imageDefinitions)
        == builtins.length (lib.unique (map (image: image.container) imageDefinitions));
      message = "my.images must map one image id to one unique container";
    }
    {
      assertion = lib.all (
        image:
        builtins.hasAttr image.container configuredContainers
        && configuredContainers.${image.container}.image == image.image
        && (configuredContainers.${image.container}.imageFile or null) == image.imageFile
        && configuredContainers.${image.container}.pull == "never"
      ) imageDefinitions;
      message = "my.images must match an OCI container with the declared image, imageFile, and pull=never";
    }
    {
      assertion =
        lib.sort builtins.lessThan (map (image: image.container) imageDefinitions)
        == lib.sort builtins.lessThan (builtins.attrNames configuredContainers);
      message = "my.images must cover every deployed OCI container exactly once";
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
      message = "my.images must use digest-locked upstream images or Nix imageFile sources";
    }
  ];
}
