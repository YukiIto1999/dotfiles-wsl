{ lib, pluginSources, localSkillsRoot, dotfilesAbs }:

# plugin と local share/skills から skill を探索し衝突を検出
let
  pluginPaths = [
    "${pluginSources.superpowers}"
    "${pluginSources.openai-plugins}/plugins/codex-security"
    "${pluginSources.claude-plugins-official}/plugins/frontend-design"
    "${pluginSources.claude-plugins-official}/plugins/skill-creator"
  ];

  findSkillsIn = pluginPath:
    let
      skillsRoot = "${pluginPath}/skills";
      entries = if builtins.pathExists skillsRoot then builtins.readDir skillsRoot else { };
      dirs = lib.filterAttrs (n: t:
        t == "directory" && builtins.pathExists "${skillsRoot}/${n}/SKILL.md"
      ) entries;
    in
      lib.mapAttrs' (name: _: lib.nameValuePair name "${skillsRoot}/${name}") dirs;

  pluginSkills = lib.foldl' (acc: p: acc // (findSkillsIn p)) { } pluginPaths;
  pluginSkillDupes =
    let
      flat   = lib.concatMap (p: builtins.attrNames (findSkillsIn p)) pluginPaths;
      counts = lib.foldl' (acc: n: acc // { ${n} = (acc.${n} or 0) + 1; }) { } flat;
    in
      builtins.attrNames (lib.filterAttrs (_: c: c > 1) counts);

  localSkills = lib.mapAttrs' (name: _:
      lib.nameValuePair name "${dotfilesAbs}/share/skills/${name}"
    ) (lib.filterAttrs (n: t:
         t == "directory" && builtins.pathExists (localSkillsRoot + "/${n}/SKILL.md")
       ) (builtins.readDir localSkillsRoot));

  localVsPluginDupes =
    builtins.filter (n: builtins.hasAttr n pluginSkills) (builtins.attrNames localSkills);
in
{
  all = pluginSkills // localSkills;
  inherit localVsPluginDupes pluginSkillDupes;
}
