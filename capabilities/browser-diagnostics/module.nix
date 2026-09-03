_: {
  config.dotfiles.capabilities.registry."browser-diagnostics" = {
    implementation = "chrome-devtools";
    providers = [ "chrome-devtools" ];
    backends = [ ];
    requiresCapabilities = [ "browser-runtime" ];
  };
}
