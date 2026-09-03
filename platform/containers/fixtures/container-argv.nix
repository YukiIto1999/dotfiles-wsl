{ pkgs, ... }:

let
  containerName = "synthetic-backend";
  secretName = "synthetic-secret.env";
  secretPath = "/run/secrets/rendered/${secretName}";
  volumeName = "synthetic-state";
  image = "registry.example.invalid/synthetic-backend:1";
  startScript = pkgs.writeText "synthetic-container-start" ''
    exec docker run --rm --name ${containerName} --network dotfiles-backends --pull never --env-file ${secretPath} -v ${volumeName}:/data ${image}
  '';
  auxiliaryScript = pkgs.writeText "synthetic-container-auxiliary" ''
    exit 0
  '';
  mkHostConfig = containerPolicy: {
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
  expected = {
    secretReaders.${secretName} = [ containerName ];
    volumeOwners.${containerName} = [ volumeName ];
  };
  valid = mkHostConfig validPolicy;
  missingSecretReader = mkHostConfig (validPolicy // { secretReaders = { }; });
  missingVolumeOwner = mkHostConfig (validPolicy // { volumeOwners = { }; });
}
