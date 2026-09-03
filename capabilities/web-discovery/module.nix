_: {
  config.dotfiles.capabilities.registry."web-discovery" = {
    implementation = "searxng";
    providers = [ "searxng" ];
    backends = [ "searxng" ];
    requiresCapabilities = [ ];
  };
}
