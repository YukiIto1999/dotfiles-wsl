_: {
  config.dotfiles.capabilities.registry."code-quality" = {
    implementation = "sonarqube";
    providers = [ "sonarqube" ];
    backends = [ "sonarqube" ];
    requiresCapabilities = [ ];
  };
}
