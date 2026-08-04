{
  helpers,
  pkgs,
  lib,
  hostConfig,
  ...
}:

{
  # image は digest で固定し、参照が repository と digest に整合すること。
  # 宣言を写した期待値は宣言と写しの一致しか見ない
  oci-image-contract =
    assert hostConfig.virtualisation.oci-containers.backend == "docker";
    assert hostConfig.virtualisation.docker.enable;
    assert lib.all (
      name:
      let
        entry = hostConfig.my.images.${name};
      in
      entry.container == name
      && (
        if entry.kind == "upstream" then
          entry.repository != null
          && entry.digest != null
          && lib.hasPrefix "sha256:" entry.digest
          && lib.hasPrefix "${entry.repository}:" entry.image
          && lib.hasSuffix "@${entry.digest}" entry.image
        else
          entry.imageFile != null && entry.repository == null && entry.digest == null
      )
    ) (builtins.attrNames hostConfig.my.images);
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
