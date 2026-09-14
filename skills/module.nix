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
  capabilityRegistryNames = builtins.attrNames config.dotfiles.capabilities.registry;
  missingSkillFiles = builtins.filter (
    name: !builtins.pathExists (cfg.registry.${name}.source + "/SKILL.md")
  ) registryNames;
  unknownRequiredCapabilities = lib.concatMap (
    name:
    map (capability: "${name}/${capability}") (
      builtins.filter (
        capability: !builtins.elem capability capabilityRegistryNames
      ) cfg.registry.${name}.requiresCapabilities
    )
  ) registryNames;
  unknownOptionalCapabilities = lib.concatMap (
    name:
    map (capability: "${name}/${capability}") (
      builtins.filter (
        capability: !builtins.elem capability capabilityRegistryNames
      ) cfg.registry.${name}.optionalCapabilities
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
  overlappingCapabilities = lib.concatMap (
    name:
    map (capability: "${name}/${capability}") (
      builtins.filter (
        capability: builtins.elem capability cfg.registry.${name}.requiresCapabilities
      ) cfg.registry.${name}.optionalCapabilities
    )
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
              type = lib.types.path;
              description = "client へ配備する SKILL.md を含む directory";
            };
            requiresCapabilities = lib.mkOption {
              type = lib.types.listOf skillIdType;
              description = "Skill の手順が利用する consumer 非依存 Capability ID";
            };
            optionalCapabilities = lib.mkOption {
              type = lib.types.listOf skillIdType;
              default = [ ];
              description = "Skill の手順が利用するとより豊かになる Capability ID";
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
      readOnly = true;
      internal = true;
      description = "resolved Capability で配備可能な Skill ID の一覧";
    };
  };
  config.dotfiles.skills.enabled = deployableSkills;

  config.assertions = [
    {
      assertion = missingSkillFiles == [ ];
      message = "Skill sources must contain SKILL.md: ${lib.concatStringsSep ", " missingSkillFiles}";
    }
    {
      assertion = unknownRequiredCapabilities == [ ] && unknownOptionalCapabilities == [ ];
      message =
        "Skills reference unknown Capabilities: "
        + lib.concatStringsSep ", " (unknownRequiredCapabilities ++ unknownOptionalCapabilities);
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
    {
      assertion = overlappingCapabilities == [ ];
      message =
        "Skill required and optional Capabilities must not overlap: "
        + lib.concatStringsSep ", " overlappingCapabilities;
    }
  ];
}
