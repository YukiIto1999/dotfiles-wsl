_: {
  config.dotfiles.capabilities.registry."heap-diagnostics" = {
    implementation = "memlab";
    providers = [ "memlab" ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
