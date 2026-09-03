_: {
  config.dotfiles.skills.registry."code-review" = {
    source = ./skill;
    requiresCapabilities = [ "code-quality" ];
    requiresSkills = [ ];
  };
}
