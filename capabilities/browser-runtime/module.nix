_: {
  imports = [ ./chromium/module.nix ];

  config.dotfiles.capabilities.registry."browser-runtime" = {
    implementation = "chromium";
    providers = [ ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
