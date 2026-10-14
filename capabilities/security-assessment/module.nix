_: {
  imports = [ ./strix/runtime/module.nix ];

  config.dotfiles.capabilities.registry."security-assessment" = {
    implementation = "strix";
    providers = [ ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
