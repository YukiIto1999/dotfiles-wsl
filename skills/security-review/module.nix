_: {
  config.dotfiles.skills.registry."security-review" = {
    source = ./skill;
    requiresCapabilities = [ ];
    optionalCapabilities = [ "security-assessment" ];
    requiresSkills = [ ];
  };
}
