_: {
  imports = [ ./playwright/mcp/module.nix ];

  config.dotfiles.capabilities.registry."browser-automation" = {
    implementation = "playwright";
    providers = [ "playwright" ];
    backends = [ ];
    requiresCapabilities = [ "browser-runtime" ];
  };
}
