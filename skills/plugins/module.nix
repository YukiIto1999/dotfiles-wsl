{
  lib,
  pluginSources,
  ...
}:

let
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
        standard-conformance = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        standard-feedback = {
          requiresCapabilities = [ "github-resources" ];
          requiresSkills = [ ];
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
  missingPluginSkills = lib.concatMap (
    sourceName:
    let
      source = adoptedPluginSkills.${sourceName};
    in
    lib.concatMap (
      skillId:
      let
        skillPath = source.source + "/skills/${skillId}/SKILL.md";
      in
      if builtins.pathExists skillPath then [ ] else [ "${sourceName}/${skillId}" ]
    ) (builtins.attrNames source.skills)
  ) pluginSourceNames;
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
    {
      assertion = missingPluginSkills == [ ];
      message = "Adopted plugin Skills must contain SKILL.md: ${lib.concatStringsSep ", " missingPluginSkills}";
    }
  ];
}
