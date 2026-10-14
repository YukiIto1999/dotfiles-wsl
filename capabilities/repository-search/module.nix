_: {
  imports = [ ./zvec-grep/mcp/module.nix ];

  config.dotfiles.capabilities.registry."repository-search" = {
    implementation = "zvec-grep";
    providers = [ "zvec-grep" ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
