_: {
  imports = [
    ./github/mcp/module.nix
    ./github/write/module.nix
  ];

  config.dotfiles.capabilities.registry."github-resources" = {
    implementation = "github";
    providers = [ "github" ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
