{
  helpers,
  pkgs,
  lib,
  hostConfig,
  variantConfig,
  ...
}:

let
  imageDefinitions = lib.concatMap (
    service:
    lib.mapAttrsToList (name: image: {
      inherit name image;
    }) service.images
  ) (builtins.attrValues hostConfig.dotfiles.containers.services);

  imageContractIsValid =
    definitions:
    definitions != [ ]
    && lib.all (
      entry:
      let
        inherit (entry) image;
      in
      image.container == entry.name
      && (
        if image.kind == "upstream" then
          image.repository != null
          && image.digest != null
          && lib.hasPrefix "sha256:" image.digest
          && lib.hasPrefix "${image.repository}:" image.image
          && lib.hasSuffix "@${image.digest}" image.image
        else
          image.imageFile != null && image.repository == null && image.digest == null
      )
    ) definitions;

  execRosterIsValid =
    scripts: containerNames:
    scripts != [ ]
    && containerNames != [ ]
    && builtins.length scripts == 3 * builtins.length containerNames;
in
{
  container-backend-contract =
    let
      fixtures = [
        (import ./fixtures/container-backend.nix { inherit lib; })
        (import ./fixtures/container-backend-minimal.nix { inherit lib; })
      ];
      mkContainerBackend = import ./impl/container-backend.nix { inherit lib; };
      actual = map (fixture: mkContainerBackend fixture.name fixture.args) fixtures;
      expected = map (fixture: fixture.expected) fixtures;
    in
    assert lib.assertMsg (actual == expected) "container backend helper output changed";
    pkgs.runCommandLocal "check-container-backend-contract" { } "touch $out";

  container-application-roster =
    let
      required = [
        "agentmemory"
        "crawl4ai"
        "searxng"
        "sonarqube"
      ];
      provided = lib.sort builtins.lessThan (builtins.attrNames hostConfig.dotfiles.containers.services);
    in
    assert required != [ ];
    assert hostConfig.dotfiles.containers.enabled == required;
    assert provided == required;
    assert variantConfig.dotfiles.containers.enabled == required;
    assert
      lib.sort builtins.lessThan (builtins.attrNames variantConfig.dotfiles.containers.services)
      == required;
    pkgs.runCommandLocal "check-container-application-roster" { } "touch $out";

  # image は digest で固定し、参照が repository と digest に整合すること。
  # 宣言を写した期待値は宣言と写しの一致しか見ない
  oci-image-contract =
    assert imageDefinitions != [ ];
    assert imageContractIsValid imageDefinitions;
    assert !(imageContractIsValid [ ]);
    assert hostConfig.virtualisation.oci-containers.backend == "docker";
    assert hostConfig.virtualisation.docker.enable;
    # pull = never なので、宣言した image が事前に無いと container が起動しない
    assert lib.all (c: c.pull == "never") (
      builtins.attrValues hostConfig.virtualisation.oci-containers.containers
    );
    pkgs.runCommandLocal "check-oci-image-contract" { } "touch $out";

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
  container-exec-content =
    let
      containerNames = builtins.attrNames hostConfig.virtualisation.oci-containers.containers;
      scripts = helpers.containerArgv.execScripts;
    in
    assert execRosterIsValid scripts containerNames;
    assert !(execRosterIsValid [ ] containerNames);
    assert !(execRosterIsValid [ ] [ ]);
    pkgs.runCommandLocal "check-container-exec-content" { } ''
      inspected=0
      for script in ${lib.escapeShellArgs scripts}; do
        inspected=$((inspected + 1))
        [ "$(head -c 2 "$script")" = '#!' ] || { echo "not a script: $script"; exit 1; }
        if grep -nE '(docker|podman)[^ ]* run ' "$script"; then
          echo "container is started outside ExecStart: $script"
          exit 1
        fi
      done
      test "$inspected" -eq ${toString (builtins.length scripts)}
      # 生成された Exec* は container ごとに ExecStart 以外が三つ。転記せず数から導く
      test "$inspected" -eq ${toString (3 * builtins.length containerNames)}
      touch $out
    '';
}
