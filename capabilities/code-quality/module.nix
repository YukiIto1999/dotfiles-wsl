_: {
  imports = [
    ./sonarqube/database/module.nix
    ./sonarqube/mcp/module.nix
    ./sonarqube/provisioning/module.nix
    ./sonarqube/scanner/module.nix
    ./sonarqube/server/module.nix
  ];

  config.dotfiles.capabilities.registry."code-quality" = {
    implementation = "sonarqube";
    providers = [ "sonarqube" ];
    backends = [ "sonarqube" ];
    requiresCapabilities = [ ];
  };
}
