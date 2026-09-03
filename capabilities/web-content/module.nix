_: {
  config.dotfiles.capabilities.registry."web-content" = {
    implementation = "crawl4ai";
    providers = [ "crawl4ai" ];
    backends = [ "crawl4ai" ];
    requiresCapabilities = [ ];
  };
}
