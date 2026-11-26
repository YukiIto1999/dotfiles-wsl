{
  config,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.workstation;
  substitutions = {
    "@dotfilesDir@" = cfg.dotfilesDir;
    "@minimumFreeGiB@" = toString cfg.nix.minimumFreeGiB;
    "@hindsightUrl@" = "http://127.0.0.1:3111";
    "@standardClone@" = "${cfg.homeDir}/.local/share/dotfiles-agent/architecture-standard";
  };
  doctor = pkgs.writeShellApplication {
    name = "dotfiles-doctor";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      findutils
      gawk
      git
      gnugrep
      procps
      systemd
    ];
    text =
      builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
        (builtins.readFile ./doctor.sh);
  };
in
{
  environment.systemPackages = [ doctor ];
}
