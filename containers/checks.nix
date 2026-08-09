{
  helpers,
  pkgs,
  lib,
  hostConfig,
  variantConfig,
  ...
}:

let
  inherit (helpers.execTokens) tokensOf;

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

  systemUnits = hostConfig.environment.etc."systemd/system".source;
in
{
  docker-buildkit-gc-contract =
    let
      daemonSettings = hostConfig.virtualisation.docker.daemon.settings;
      gcService = hostConfig.systemd.services.docker-buildkit-gc or null;
      gcTimer = hostConfig.systemd.timers.docker-buildkit-gc or null;
      execTokens = if gcService == null then [ ] else tokensOf gcService.serviceConfig.ExecStart;
      dependencyFields = [
        "after"
        "before"
        "bindsTo"
        "conflicts"
        "joinsNamespaceOf"
        "onFailure"
        "onSuccess"
        "partOf"
        "propagatesReloadTo"
        "reloadPropagatedFrom"
        "requires"
        "requisite"
        "upholds"
        "wants"
      ];
      gcDependents = lib.concatLists (
        lib.mapAttrsToList (
          name: service:
          map (field: "${name}.${field}") (
            builtins.filter (
              field: lib.elem "docker-buildkit-gc.service" (service.${field} or [ ])
            ) dependencyFields
          )
        ) hostConfig.systemd.services
      );
    in
    assert lib.assertMsg (
      lib.attrByPath [ "builder" "gc" "enabled" ] null daemonSettings == true
    ) "Docker BuildKit GC must be enabled";
    assert lib.assertMsg (
      lib.attrByPath [ "builder" "gc" "defaultKeepStorage" ] null daemonSettings == "60GB"
    ) "Docker BuildKit GC must retain 60GB by default";
    assert lib.assertMsg (gcService != null) "Docker BuildKit GC service is missing";
    assert lib.assertMsg (gcService.after == [ "docker.service" ]) (
      "Docker BuildKit GC service must start after Docker: actual=${builtins.toJSON gcService.after}"
    );
    assert lib.assertMsg (gcService.wants == [ "docker.service" ]) (
      "Docker BuildKit GC service must use a soft Docker dependency: actual=${builtins.toJSON gcService.wants}"
    );
    assert lib.assertMsg (gcService.requires == [ ] && gcService.requiredBy == [ ]) (
      "Docker BuildKit GC failure must not propagate to Docker"
    );
    assert lib.assertMsg (gcDependents == [ ]) (
      "system services must not depend on Docker BuildKit GC: actual=${builtins.toJSON gcDependents}"
    );
    assert lib.assertMsg (gcService.serviceConfig.Type == "oneshot") (
      "Docker BuildKit GC service must be oneshot"
    );
    assert lib.assertMsg (
      gcService.unitConfig.ConditionPathExists == "/var/run/docker.sock"
    ) "Docker BuildKit GC service must require the Docker socket";
    assert lib.assertMsg (
      execTokens == [
        (lib.getExe pkgs.docker)
        "buildx"
        "prune"
        "--force"
        "--max-used-space"
        "60GB"
        "--reserved-space"
        "20GB"
      ]
    ) "Docker BuildKit GC command changed: actual=${builtins.toJSON execTokens}";
    assert lib.assertMsg (gcTimer != null) "Docker BuildKit GC timer is missing";
    assert lib.assertMsg (gcTimer.wantedBy == [ "timers.target" ]) (
      "Docker BuildKit GC timer must be enabled: actual=${builtins.toJSON gcTimer.wantedBy}"
    );
    assert lib.assertMsg (
      gcTimer.timerConfig == {
        OnCalendar = "*-*-* 00/6:00:00";
        Persistent = true;
        Unit = "docker-buildkit-gc.service";
      }
    ) "Docker BuildKit GC timer must run persistently every six hours";
    pkgs.runCommandLocal "check-docker-buildkit-gc-contract"
      {
        nativeBuildInputs = [
          pkgs.findutils
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail

        if grep -HnE '^(After|Before|BindsTo|Conflicts|JoinsNamespaceOf|OnFailure|OnSuccess|PartOf|PropagatesReloadTo|ReloadPropagatedFrom|Requires|Requisite|Upholds|Wants)=(.*[[:space:]])?docker-buildkit-gc\.service([[:space:]]|$)' ${systemUnits}/*.service > service-dependencies; then
          cat service-dependencies >&2
          exit 1
        fi

        find ${systemUnits} -mindepth 2 -type l -lname '*docker-buildkit-gc.service' -print > dependency-links
        if [ -s dependency-links ]; then
          cat dependency-links >&2
          exit 1
        fi

        touch $out
      '';

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
