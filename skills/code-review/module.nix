_: {
  config.dotfiles.skills.registry."code-review" = {
    source = ./skill;
    requiresCapabilities = [ ];
    optionalCapabilities = [ "code-quality" ];
    requiresSkills = [ ];
  };
}
