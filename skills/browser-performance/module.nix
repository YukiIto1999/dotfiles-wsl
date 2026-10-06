_: {
  config.dotfiles.skills.registry."browser-performance" = {
    source = ./skill;
    requiresCapabilities = [ "browser-diagnostics" ];
    requiresSkills = [ "debug-optimize-lcp" ];
  };
}
