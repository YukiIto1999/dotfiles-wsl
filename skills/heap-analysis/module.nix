_: {
  config.dotfiles.skills.registry."heap-analysis" = {
    source = ./skill;
    requiresCapabilities = [ "heap-diagnostics" ];
    requiresSkills = [ ];
  };
}
