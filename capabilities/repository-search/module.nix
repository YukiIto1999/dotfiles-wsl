_: {
  config.dotfiles.capabilities.registry."repository-search" = {
    implementation = "zvec-grep";
    providers = [ "zvec-grep" ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
