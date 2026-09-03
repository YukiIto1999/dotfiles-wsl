_: {
  config.dotfiles.capabilities.registry."project-memory" = {
    implementation = "agentmemory";
    providers = [ "memory" ];
    backends = [ "agentmemory" ];
    requiresCapabilities = [ ];
  };
}
