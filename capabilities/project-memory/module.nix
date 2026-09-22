_: {
  config.dotfiles.capabilities.registry."project-memory" = {
    implementation = "hindsight";
    providers = [ "memory" ];
    backends = [ "hindsight" ];
    requiresCapabilities = [ ];
  };
}
