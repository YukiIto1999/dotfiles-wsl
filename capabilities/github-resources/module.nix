_: {
  config.dotfiles.capabilities.registry."github-resources" = {
    implementation = "github";
    providers = [ "github" ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
