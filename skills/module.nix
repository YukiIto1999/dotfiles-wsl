{
  config,
  lib,
  ...
}:

let
  cfg = config.dotfiles.skills;
  skillIdType = lib.types.addCheck lib.types.str (
    value: value != "" && builtins.match "[a-z0-9]+(-[a-z0-9]+)*" value != null
  );
  registryNames = builtins.attrNames cfg.registry;
  missingSkillFiles = builtins.filter (
    name: !builtins.pathExists (cfg.registry.${name}.source + "/SKILL.md")
  ) registryNames;
  unknownEnabled = builtins.filter (name: !builtins.hasAttr name cfg.registry) cfg.enabled;
  duplicateEnabled = builtins.length cfg.enabled != builtins.length (lib.unique cfg.enabled);
  unknownSkillDependencies = lib.concatMap (
    name:
    map (dependency: "${name}/${dependency}") (
      builtins.filter (
        dependency: !builtins.hasAttr dependency cfg.registry
      ) cfg.registry.${name}.requiresSkills
    )
  ) registryNames;
  duplicateDependencies = builtins.filter (
    name:
    let
      skill = cfg.registry.${name};
    in
    builtins.length skill.requiresCapabilities
    != builtins.length (lib.unique skill.requiresCapabilities)
    || builtins.length skill.requiresSkills != builtins.length (lib.unique skill.requiresSkills)
  ) registryNames;
  disabledRequiredSkills = lib.concatMap (
    name:
    if builtins.hasAttr name cfg.registry then
      map (dependency: "${name}/${dependency}") (
        builtins.filter (
          dependency: !builtins.elem dependency cfg.enabled
        ) cfg.registry.${name}.requiresSkills
      )
    else
      [ ]
  ) cfg.enabled;
in
{
  options.dotfiles.skills = {
    registry = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.path;
              description = "client へ配備する SKILL.md を含む directory";
            };
            requiresCapabilities = lib.mkOption {
              type = lib.types.listOf skillIdType;
              description = "Skill の手順が利用する consumer 非依存 Capability ID";
            };
            requiresSkills = lib.mkOption {
              type = lib.types.listOf skillIdType;
              description = "Skill の手順が合成する別の Skill ID";
            };
          };
        }
      );
      default = { };
      internal = true;
      description = "利用可能な Skill unit と依存 contract";
    };

    enabled = lib.mkOption {
      type = lib.types.listOf skillIdType;
      description = "全 agent client へ配備する Skill ID の重複しない一覧";
    };
  };

  config.assertions = [
    {
      assertion = cfg.enabled != [ ] && !duplicateEnabled;
      message = "dotfiles.skills.enabled must be non-empty and contain no duplicate Skill IDs";
    }
    {
      assertion = unknownEnabled == [ ];
      message = "Unknown enabled Skill IDs: ${lib.concatStringsSep ", " unknownEnabled}";
    }
    {
      assertion = missingSkillFiles == [ ];
      message = "Skill sources must contain SKILL.md: ${lib.concatStringsSep ", " missingSkillFiles}";
    }
    {
      assertion = unknownSkillDependencies == [ ];
      message = "Unknown Skill dependencies: ${lib.concatStringsSep ", " unknownSkillDependencies}";
    }
    {
      assertion = duplicateDependencies == [ ];
      message = "Skill dependency lists must not contain duplicates: ${lib.concatStringsSep ", " duplicateDependencies}";
    }
    {
      assertion = disabledRequiredSkills == [ ];
      message = "Enabled Skills require disabled Skills: ${lib.concatStringsSep ", " disabledRequiredSkills}";
    }
  ];
}
