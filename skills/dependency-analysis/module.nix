_: {
  config.dotfiles.skills.registry."dependency-analysis" = {
    source = ./skill;
    requiresCapabilities = [ ];
    requiresSkills = [ "repository-research" ];
  };
}
