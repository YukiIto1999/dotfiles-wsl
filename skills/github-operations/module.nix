_: {
  config.dotfiles.skills.registry."github-operations" = {
    source = ./skill;
    requiresCapabilities = [ "github-resources" ];
    requiresSkills = [ ];
  };
}
