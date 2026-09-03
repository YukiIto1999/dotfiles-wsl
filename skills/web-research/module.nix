_: {
  config.dotfiles.skills.registry."web-research" = {
    source = ./skill;
    requiresCapabilities = [
      "library-documentation"
      "web-content"
      "web-discovery"
    ];
    requiresSkills = [ "repository-research" ];
  };
}
