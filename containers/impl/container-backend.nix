{ lib }:

name:
{
  image,
  imageFile ? null,
  environmentFiles ? [ ],
  volumes ? [ ],
  extraOptions ? [ ],
  ports ? [ ],
  deps ? [ ],
}:
let
  networkUnit = "docker-dotfiles-backends-network.service";
in
{
  containers."${name}" = {
    inherit image;
    pull = "never";
  }
  // lib.optionalAttrs (imageFile != null) { inherit imageFile; }
  // lib.optionalAttrs (environmentFiles != [ ]) { inherit environmentFiles; }
  // lib.optionalAttrs (volumes != [ ]) { inherit volumes; }
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

  systemdServices."docker-${name}" = {
    after = [ networkUnit ] ++ deps;
    requires = [ networkUnit ] ++ deps;
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = "5s";
    };
  };
}
