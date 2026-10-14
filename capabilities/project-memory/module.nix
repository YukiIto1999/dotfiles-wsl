_: {
  imports = [
    ./hindsight/backend/module.nix
    ./hindsight/client-integrations/module.nix
    ./hindsight/mcp/module.nix
    ./hindsight/runtime/module.nix
  ];

  config.dotfiles.capabilities.registry."project-memory" = {
    implementation = "hindsight";
    providers = [ "memory" ];
    backends = [ "hindsight" ];
    requiresCapabilities = [ ];
  };
}
