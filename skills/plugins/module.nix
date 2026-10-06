{
  lib,
  pluginSources,
  ...
}:

let
  # upstream の追加による採用集合の暗黙変更を防ぐため directory の自動列挙は不採用
  adoptedPluginSkills = {
    orca = {
      source = pluginSources.orca;
      skills = {
        orca-cli = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        orchestration = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        computer-use = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        orca-emulator = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        orca-emulator-android = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        orca-linear = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        orca-per-workspace-env = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
      };
    };
    architecture-standard = {
      source = pluginSources.architecture-standard;
      skills = {
        standard-apply = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        standard-audit = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        standard-conformance = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        standard-feedback = {
          requiresCapabilities = [ "github-resources" ];
          requiresSkills = [ ];
        };
        standard-update = {
          requiresCapabilities = [ ];
          requiresSkills = [
            "standard-audit"
            "web-research"
          ];
        };
      };
    };
  };
  pluginSourceNames = builtins.attrNames adoptedPluginSkills;
  pluginSkillNames = lib.concatMap (
    sourceName: builtins.attrNames adoptedPluginSkills.${sourceName}.skills
  ) pluginSourceNames;
  duplicatePluginSkills = lib.unique (
    builtins.filter (
      name: lib.count (candidate: candidate == name) pluginSkillNames > 1
    ) pluginSkillNames
  );
  pluginSkills = lib.concatMapAttrs (
    _: source:
    lib.mapAttrs (
      skillId: metadata:
      metadata
      // {
        source = source.source + "/skills/${skillId}";
      }
    ) source.skills
  ) adoptedPluginSkills;
in
{
  config.dotfiles.skills.registry = pluginSkills;

  config.assertions = [
    {
      assertion = duplicatePluginSkills == [ ];
      message = "Duplicate Skill IDs across plugins: ${lib.concatStringsSep ", " duplicatePluginSkills}";
    }
  ];
}
