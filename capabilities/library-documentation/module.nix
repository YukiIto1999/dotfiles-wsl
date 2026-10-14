_: {
  imports = [ ./context7/mcp/module.nix ];

  config.dotfiles.capabilities.registry."library-documentation" = {
    implementation = "context7";
    providers = [ "context7" ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
