_: {
  imports = [ ./binlog/mcp/module.nix ];

  config.dotfiles.capabilities.registry."build-diagnostics" = {
    implementation = "binlog";
    providers = [ "binlog" ];
    backends = [ ];
    requiresCapabilities = [ ];
  };
}
