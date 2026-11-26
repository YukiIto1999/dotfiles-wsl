{
  config,
  pkgs,
  self,
  ...
}:

let
  substitutions = {
    "@dotfilesDir@" = config.dotfiles.workstation.dotfilesDir;
    "@hostName@" = config.networking.hostName;
    "@nixosRebuild@" = "${config.system.build.nixos-rebuild}/bin/nixos-rebuild";
  };
  rebuild = pkgs.writeShellApplication {
    name = "dotfiles-rebuild";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      git
      nix
      util-linux
    ];
    text =
      builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
        (builtins.readFile ./rebuild.sh);
  };
in
{
  environment.systemPackages = [ rebuild ];

  # dotfiles-doctor compares this with the checkout's HEAD to tell whether the running system is current
  system.configurationRevision = self.rev or self.dirtyRev or null;
}
