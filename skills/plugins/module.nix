{
  lib,
  pluginSources,
  ...
}:

let
  pluginPaths = [
    (pluginSources.openai-plugins + "/plugins/codex-security")
  ];
  findSkillsIn =
    pluginPath:
    let
      skillsRoot = pluginPath + "/skills";
      entries = if builtins.pathExists skillsRoot then builtins.readDir skillsRoot else { };
    in
    lib.mapAttrs' (name: _: lib.nameValuePair name (skillsRoot + "/${name}")) (
      lib.filterAttrs (
        name: type: type == "directory" && builtins.pathExists (skillsRoot + "/${name}/SKILL.md")
      ) entries
    );
  pluginSkills = lib.foldl' (skills: path: skills // findSkillsIn path) { } pluginPaths;
  pluginSkillNames = lib.concatMap (path: builtins.attrNames (findSkillsIn path)) pluginPaths;
  duplicatePluginSkills = lib.unique (
    builtins.filter (
      name: lib.count (candidate: candidate == name) pluginSkillNames > 1
    ) pluginSkillNames
  );
in
{
  config = {
    dotfiles.skills.registry = lib.mapAttrs (_: source: {
      inherit source;
      requiresCapabilities = [ ];
      requiresSkills = [ ];
    }) pluginSkills;

    assertions = [
      {
        assertion = duplicatePluginSkills == [ ];
        message = "Duplicate Skill IDs across plugins: ${lib.concatStringsSep ", " duplicatePluginSkills}";
      }
    ];
  };
}
