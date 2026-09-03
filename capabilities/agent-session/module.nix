_: {
  config.dotfiles.capabilities.registry."agent-session" = {
    implementation = "codex";
    providers = [ "codex" ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
