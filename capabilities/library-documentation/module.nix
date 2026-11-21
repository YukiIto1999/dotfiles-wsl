_: {
  imports = [
    ./context7/mcp/module.nix
    ./remote/mcp/module.nix
  ];

  config.dotfiles.capabilities.registry."library-documentation" = {
    implementation = "public-documentation";
    providers = [
      "context7"
      "deepwiki"
      "microsoft-learn"
    ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
