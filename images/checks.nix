{
  helpers,
  pkgs,
  lib,
  self,
  hostConfig,
  ...
}:

let
  inherit (helpers.execTokens) valuesOf;
  inherit (helpers.containerArgv)
    containerArgv
    ;
  nixImageIdentityFiles = hostConfig.my.contract.images.identityFiles;
  expectedUpstreamOciImages = {
    crawl4ai = {
      container = "crawl4ai";
      digest = "sha256:bd36741e7bdd35ddc1a05d9183e1d6d8cefb61dd640d944a25d026b76e917690";
      image = "unclecode/crawl4ai:latest@sha256:bd36741e7bdd35ddc1a05d9183e1d6d8cefb61dd640d944a25d026b76e917690";
      repository = "unclecode/crawl4ai";
    };
    searxng = {
      container = "searxng";
      digest = "sha256:ec536bcd1e83577aad4cc07f7ecb9a30858a9a905d2d57c8796abc83f872a036";
      image = "searxng/searxng:2026.8.1-8892414dc@sha256:ec536bcd1e83577aad4cc07f7ecb9a30858a9a905d2d57c8796abc83f872a036";
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
  ) (lib.filterAttrs (_: image: image.kind == "upstream") hostConfig.my.images);
  agentmemoryOciImage = hostConfig.my.images.agentmemory;
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
    }) hostConfig.my.images;
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
    # extraOptions の後勝ちで --pull=always が効く。宣言ではなく argv を見る
    assert lib.all (name: valuesOf containerArgv.${name} "--pull" == [ "never" ]) (
      builtins.attrNames hostConfig.virtualisation.oci-containers.containers
    );
    assert
      actualOciPullModes == {
        agentmemory = "never";
        crawl4ai = "never";
        searxng = "never";
        sonarqube = "never";
        sonarqube-db = "never";
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

  # docker が受け取る argv の contract。宣言のどの経路から来ても argv に現れるので、
  # extraOptions だけを見ると networks や user を取り逃す
  container-argv-contract =
    assert lib.assertMsg (helpers.containerArgv.staleSecretReaders == [ ]) (
      "secret reader table names a template that does not exist: "
      + lib.concatStringsSep " " helpers.containerArgv.staleSecretReaders
    );
    assert lib.assertMsg (helpers.containerArgv.unexpectedTokens == [ ]) (
      "container run has tokens outside the allowed vocabulary: "
      + lib.concatStringsSep " " helpers.containerArgv.unexpectedTokens
    );
    assert lib.assertMsg (helpers.containerArgv.wrongValues == [ ]) (
      "container run passes a value outside its contract: "
      + lib.concatStringsSep " " helpers.containerArgv.wrongValues
    );
    assert lib.assertMsg (helpers.containerArgv.missingFlags == [ ]) (
      "container run omits a flag whose value must be checked: "
      + lib.concatStringsSep " " helpers.containerArgv.missingFlags
    );
    assert lib.assertMsg (helpers.containerArgv.strayExec == [ ]) (
      "container unit has Exec* outside the generated set: "
      + lib.concatStringsSep " " helpers.containerArgv.strayExec
    );
    assert lib.assertMsg (helpers.containerArgv.sharedVolumes == [ ]) (
      "named volume is mounted by more than one container: "
      + lib.concatStringsSep " " helpers.containerArgv.sharedVolumes
    );
    pkgs.runCommandLocal "check-container-argv-contract" { } "touch $out";

  # Exec* の key 集合だけでは、生成された script の中身までは見えない
  container-exec-content = pkgs.runCommandLocal "check-container-exec-content" { } ''
    inspected=0
    for script in ${lib.escapeShellArgs helpers.containerArgv.execScripts}; do
      inspected=$((inspected + 1))
      [ "$(head -c 2 "$script")" = '#!' ] || { echo "not a script: $script"; exit 1; }
      if grep -nE '(docker|podman)[^ ]* run ' "$script"; then
        echo "container is started outside ExecStart: $script"
        exit 1
      fi
    done
    test "$inspected" -eq ${toString (builtins.length helpers.containerArgv.execScripts)}
    # 生成された Exec* は container ごとに ExecStart 以外が三つ。転記せず数から導く
    test "$inspected" -eq ${
      toString (
        3 * builtins.length (builtins.attrNames hostConfig.virtualisation.oci-containers.containers)
      )
    }
    touch $out
  '';
}
