_: {
  config.dotfiles.capabilities.registry."browser-automation" = {
    implementation = "playwright";
    providers = [ "playwright" ];
    backends = [ ];
    requiresCapabilities = [ "browser-runtime" ];
  };
}
