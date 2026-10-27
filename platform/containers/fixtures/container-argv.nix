let
  # 実 host と同じ slice 名では固定値を埋め込んだ検証も通ってしまうため実 host の名前は不可
  slices = {
    support = "synthetic-workload.slice";
    containers = "synthetic-workload-containers.slice";
  };
in
{
  pkgs,
  stopTimeout ? null,
  cgroupParent ? slices.support,
  extraOptions ? [ ],
  ...
}:

let
  containerName = "synthetic-backend";
  secretName = "synthetic-secret.env";
  secretPath = "/run/secrets/rendered/${secretName}";
  volumeName = "synthetic-state";
  image = "registry.example.invalid/synthetic-backend:1";
  startScript = pkgs.writeText "synthetic-container-start" ''
    docker run --rm --name ${containerName} --network dotfiles-backends ${
      if cgroupParent == null then "" else "--cgroup-parent=${cgroupParent}"
    } --pull never --env-file ${secretPath} -v ${volumeName}:/data ${
      if stopTimeout == null then "" else "--stop-timeout=${stopTimeout}"
    } ${builtins.concatStringsSep " " extraOptions} ${image}
  '';
  auxiliaryScript = pkgs.writeText "synthetic-container-auxiliary" ''
    exit 0
  '';
  mkHostConfig = containerPolicy: {
    dotfiles.workstation.workload = { inherit slices; };
    dotfiles.platform.containers.services.synthetic-service = {
      inherit containerPolicy;
    };
    sops.templates.${secretName}.path = secretPath;
    virtualisation.oci-containers.containers.${containerName}.image = image;
    systemd.services."docker-${containerName}".serviceConfig = {
      ExecStart = startScript;
      ExecStartPre = auxiliaryScript;
      ExecStop = auxiliaryScript;
      ExecStopPost = auxiliaryScript;
    };
  };
  validPolicy = {
    secretReaders.${secretName} = [ containerName ];
    volumeOwners.${containerName} = [ volumeName ];
  };
in
{
  inherit slices;
  expected = {
    secretReaders.${secretName} = [ containerName ];
    volumeOwners.${containerName} = [ volumeName ];
  };
  valid = mkHostConfig validPolicy;
  missingSecretReader = mkHostConfig (validPolicy // { secretReaders = { }; });
  missingVolumeOwner = mkHostConfig (validPolicy // { volumeOwners = { }; });
}
