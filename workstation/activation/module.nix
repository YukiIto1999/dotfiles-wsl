_: {
  system.stateVersion = "25.11";

  dotfiles.health.observations."host/system-generation" = {
    kind = "path-match";
    checkId = "system-generation";
    resourceKey = null;
    timeoutSeconds = 10;
    failureMessage = "could not resolve the current system generation";
    currentPath = "/run/current-system";
    requiredPath = "/nix/var/nix/profiles/system";
    resolution = "canonical";
  };
}
