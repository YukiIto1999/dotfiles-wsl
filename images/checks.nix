{
  pkgs,
  lib,
  self,
  hostConfig,
  ...
}:

let
  nixImageIdentityFiles = hostConfig.my.contract.images.identityFiles;
  expectedUpstreamOciImages = {
    crawl4ai = {
      container = "crawl4ai";
      digest = "sha256:a45fd08f8f15f67026c1bff0a151f0479244caf6751a0c6943b3870efafcd025";
      image = "unclecode/crawl4ai:latest@sha256:a45fd08f8f15f67026c1bff0a151f0479244caf6751a0c6943b3870efafcd025";
      repository = "unclecode/crawl4ai";
    };
    searxng = {
      container = "searxng";
      digest = "sha256:25ff3c045548971d12726e54bea4564b8ec3bedb3d6951aecdefd01caf840974";
      image = "searxng/searxng:2026.5.17-d7e8b7cd1@sha256:25ff3c045548971d12726e54bea4564b8ec3bedb3d6951aecdefd01caf840974";
      repository = "searxng/searxng";
    };
    sonarqube = {
      container = "sonarqube";
      digest = "sha256:5a40959752dcc1e1408ff18d8ce35be30711323ed5612d3a49d65e093dc34454";
      image = "sonarqube:community@sha256:5a40959752dcc1e1408ff18d8ce35be30711323ed5612d3a49d65e093dc34454";
      repository = "sonarqube";
    };
    sonarqube-db = {
      container = "sonarqube-db";
      digest = "sha256:af194ccf3e2d7fe367012c7b88ce8b816c5c889b18a5b316799a1f0d7eac746a";
      image = "postgres:17-alpine@sha256:af194ccf3e2d7fe367012c7b88ce8b816c5c889b18a5b316799a1f0d7eac746a";
      repository = "postgres";
    };
    valkey = {
      container = "valkey";
      digest = "sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9";
      image = "valkey/valkey:latest@sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9";
      repository = "valkey/valkey";
    };
  };
  actualUpstreamOciImages = lib.mapAttrs (
    _: image:
    lib.filterAttrs (
      name: _:
      lib.elem name [
        "container"
        "digest"
        "image"
        "repository"
      ]
    ) image
  ) (lib.filterAttrs (_: image: image.kind == "upstream") hostConfig.my.ociImages);
  agentmemoryOciImage = hostConfig.my.ociImages.agentmemory;
  actualOciPullModes = lib.mapAttrs (
    _: container: container.pull
  ) hostConfig.virtualisation.oci-containers.containers;
  ociContainerStartScripts = map (
    containerName:
    lib.removeSuffix " " hostConfig.systemd.services."docker-${containerName}".serviceConfig.ExecStart
  ) (builtins.attrNames hostConfig.virtualisation.oci-containers.containers);
  expectedOciImageManifest = {
    schemaVersion = 2;
    images = lib.mapAttrsToList (id: image: {
      inherit id;
      inherit (image)
        kind
        container
        image
        repository
        digest
        ;
      imageFile = if image.imageFile == null then null else toString image.imageFile;
    }) hostConfig.my.ociImages;
  };
  syncImages = hostConfig.my.commands.syncImages;
  syncImagesTest = syncImages.testPackage;
in
{
  oci-image-contract =
    assert hostConfig.virtualisation.oci-containers.backend == "docker";
    assert hostConfig.virtualisation.docker.enable;
    assert actualUpstreamOciImages == expectedUpstreamOciImages;
    assert agentmemoryOciImage.kind == "nix";
    assert agentmemoryOciImage.container == "agentmemory";
    assert agentmemoryOciImage.image == "agentmemory:0.9.26";
    assert agentmemoryOciImage.repository == null;
    assert agentmemoryOciImage.digest == null;
    assert agentmemoryOciImage.imageFile != null;
    assert builtins.attrNames nixImageIdentityFiles == [ "agentmemory" ];
    assert
      actualOciPullModes == {
        agentmemory = "never";
        crawl4ai = "never";
        searxng = "never";
        sonarqube = "never";
        sonarqube-db = "never";
        valkey = "never";
      };
    assert
      hostConfig.environment.etc."dotfiles/oci-images.json".source
      == hostConfig.my.commands.syncImages.manifest;
    pkgs.runCommandLocal "check-oci-image-contract"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
          pkgs.util-linux
        ];
      }
      ''
        jq --exit-status \
          --argjson expected ${lib.escapeShellArg (builtins.toJSON expectedOciImageManifest)} \
          '. == $expected' \
          ${syncImages.manifest} > /dev/null
        jq --exit-status \
          --arg reference ${lib.escapeShellArg agentmemoryOciImage.image} \
          --arg imageFile ${lib.escapeShellArg (toString agentmemoryOciImage.imageFile)} '
            .schemaVersion == 1 and
            .imageReference == $reference and
            .imageFile == $imageFile and
            (.imageId | type == "string" and test("^sha256:[0-9a-f]{64}$"))
          ' ${nixImageIdentityFiles.agentmemory} > /dev/null
        if grep --recursive --quiet 'DOTFILES_IMAGE_SYNC_TEST_' ${syncImages}; then
          echo 'production dotfiles-sync-images contains test hooks' >&2
          exit 1
        fi
        for start_script in ${lib.escapeShellArgs ociContainerStartScripts}; do
          grep --fixed-strings -- '--pull never' "$start_script" > /dev/null
        done
        bash ${self}/images/tests/sync-images-runtime.sh ${lib.getExe syncImagesTest}
        touch $out
      '';
}
