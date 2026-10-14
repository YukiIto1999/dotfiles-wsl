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
  invalidSkillIds = builtins.filter (name: !skillIdType.check name) registryNames;
  capabilityRegistryNames = builtins.attrNames config.dotfiles.capabilities.registry;
  invalidSkillSources = builtins.filter (
    name:
    let
      source = cfg.registry.${name}.source;
    in
    !builtins.pathExists (source + "/SKILL.md") || (builtins.readDir source)."SKILL.md" != "regular"
  ) registryNames;
  unknownCapabilities = lib.concatMap (
    name:
    map (capability: "${name}/${capability}") (
      builtins.filter (capability: !builtins.elem capability capabilityRegistryNames) (
        cfg.registry.${name}.requiresCapabilities ++ cfg.registry.${name}.optionalCapabilities
      )
    )
  ) registryNames;
  unknownSkillDependencies = lib.concatMap (
    name:
    map (dependency: "${name}/${dependency}") (
      builtins.filter (
        dependency: !builtins.hasAttr dependency cfg.registry
      ) cfg.registry.${name}.requiresSkills
    )
  ) registryNames;
  duplicateMetadata = lib.concatMap (
    name:
    let
      skill = cfg.registry.${name};
      duplicate = values: builtins.length values != builtins.length (lib.unique values);
    in
    lib.optional (duplicate skill.requiresCapabilities) "${name}/requiresCapabilities"
    ++ lib.optional (duplicate skill.optionalCapabilities) "${name}/optionalCapabilities"
    ++ lib.optional (duplicate skill.requiresSkills) "${name}/requiresSkills"
  ) registryNames;
  skillClosure =
    initial:
    let
      visit =
        pending: visited:
        if pending == [ ] then
          visited
        else
          let
            name = builtins.head pending;
            remaining = builtins.tail pending;
            dependencies =
              if builtins.hasAttr name cfg.registry then cfg.registry.${name}.requiresSkills else [ ];
          in
          if builtins.elem name visited then
            visit remaining visited
          else
            visit (remaining ++ dependencies) (visited ++ [ name ]);
    in
    visit initial [ ];
  requiredCapabilitiesFor =
    name:
    lib.unique (
      lib.concatMap (
        dependency:
        if builtins.hasAttr dependency cfg.registry then
          cfg.registry.${dependency}.requiresCapabilities
        else
          [ ]
      ) (skillClosure [ name ])
    );
  deployableSkills = builtins.filter (
    name:
    lib.all (capability: builtins.elem capability config.dotfiles.capabilities.resolved) (
      requiredCapabilitiesFor name
    )
  ) registryNames;
in
{
  options.dotfiles.skills = {
    registry = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.uniq lib.types.path;
              description = "client へ本文と資材をそのまま配備する SKILL.md 所在 directory";
            };
            requiresCapabilities = lib.mkOption {
              type = (lib.types.listOf skillIdType) // {
                emptyValue = { };
              };
              description = "Skill 全体の配備に必要な consumer 非依存 Capability ID";
            };
            optionalCapabilities = lib.mkOption {
              type = lib.types.listOf skillIdType;
              default = [ ];
              description = "条件付き手順の入口として利用する Capability ID。未配備でも Skill 全体は利用可能";
            };
            requiresSkills = lib.mkOption {
              type = (lib.types.listOf skillIdType) // {
                emptyValue = { };
              };
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
      readOnly = true;
      internal = true;
      description = "resolved Capability で配備可能な Skill ID の一覧";
    };
  };
  config.dotfiles.skills.enabled = deployableSkills;

  config.assertions = [
    {
      assertion = invalidSkillIds == [ ];
      message = "Skill IDs must use safe kebab-case: ${lib.concatStringsSep ", " invalidSkillIds}";
    }
    {
      assertion = invalidSkillSources == [ ];
      message =
        "Skill sources must contain a regular SKILL.md file: "
        + lib.concatStringsSep ", " invalidSkillSources;
    }
    {
      assertion = unknownCapabilities == [ ];
      message = "Skills reference unknown Capabilities: ${lib.concatStringsSep ", " unknownCapabilities}";
    }
    {
      assertion = unknownSkillDependencies == [ ];
      message = "Unknown Skill dependencies: ${lib.concatStringsSep ", " unknownSkillDependencies}";
    }
    {
      assertion = duplicateMetadata == [ ];
      message =
        "Skill metadata lists must not contain duplicates: " + lib.concatStringsSep ", " duplicateMetadata;
    }
  ];
}
