{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  expectedRepository = "ghcr.io/vectorize-io/hindsight";
  expectedDigest = "sha256:ba46d6f4ecadb93f71747428e39fd429df0e0adfc0c066b76a365c06b219db8b";
  expectedImage = "${expectedRepository}:0.10.1@${expectedDigest}";
  expectedEnvironmentFile = "/run/secrets/rendered/hindsight.env";
  expectedPersistentMount = "hindsight-data:/home/hindsight/.pg0";
  expectedUnit = "docker-hindsight.service";

  service = hostConfig.dotfiles.platform.containers.services.hindsight;
  image = service.images.hindsight;
  container = hostConfig.virtualisation.oci-containers.containers.hindsight;
  environmentTemplate = hostConfig.sops.templates."hindsight.env";
  systemdService = hostConfig.systemd.services.docker-hindsight;
  volumes = container.volumes or [ ];
  modelMounts = builtins.filter (mount: lib.hasInfix "/opt/hindsight/models/" mount) volumes;
in
{
  hindsight-container =
    assert
      service.endpoints.http == {
        protocol = "http";
        address = "127.0.0.1";
        port = 3111;
        url = "http://127.0.0.1:3111";
      };
    assert service.units == [ expectedUnit ];
    assert
      service.health == {
        endpoint = "http";
        method = "GET";
        path = "/health/ready";
        timeout = 5;
      };
    assert
      service.containerPolicy == {
        secretReaders."hindsight.env" = [ "hindsight" ];
        volumeOwners.hindsight = [ "hindsight-data" ];
      };
    assert
      image == {
        kind = "upstream";
        container = "hindsight";
        image = expectedImage;
        repository = expectedRepository;
        digest = expectedDigest;
        imageFile = null;
      };
    assert container.image == expectedImage;
    assert container.pull == "never";
    assert lib.count (mount: mount == expectedPersistentMount) volumes == 1;
    assert builtins.length modelMounts == 2;
    assert lib.all (
      mount:
      lib.hasSuffix ":ro" mount && lib.hasPrefix "/nix/store/" (builtins.head (lib.splitString ":" mount))
    ) modelMounts;
    assert container.user == null;
    assert lib.all (option: !(lib.hasPrefix "--user=" option)) container.extraOptions;
    assert lib.elem "--stop-timeout=45" container.extraOptions;
    assert systemdService.serviceConfig.TimeoutStopSec == "60s";
    assert container.environmentFiles == [ expectedEnvironmentFile ];
    assert environmentTemplate.path == expectedEnvironmentFile;
    assert environmentTemplate.mode == "0400";
    assert environmentTemplate.owner == "root";
    assert environmentTemplate.group == "root";
    assert environmentTemplate.restartUnits == [ expectedUnit ];
    assert lib.hasInfix hostConfig.sops.placeholder."opencode/go_api_key" environmentTemplate.content;
    pkgs.runCommandLocal "check-hindsight-container" { } "touch $out";
}
