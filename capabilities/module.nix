{
  config,
  lib,
  ...
}:

let
  cfg = config.dotfiles.capabilities;
  capabilityIdValid = value: value != "" && builtins.match "[a-z0-9]+(-[a-z0-9]+)*" value != null;
  capabilityIdType = lib.types.addCheck lib.types.str capabilityIdValid;
  registryNames = builtins.attrNames cfg.registry;
  invalidRegistryNames = builtins.filter (name: !capabilityIdValid name) registryNames;
  unknownEnabled = builtins.filter (name: !builtins.hasAttr name cfg.registry) cfg.enabled;
  duplicateEnabled = builtins.length cfg.enabled != builtins.length (lib.unique cfg.enabled);
  duplicateValues = values: builtins.length values != builtins.length (lib.unique values);
  duplicateMetadata = builtins.filter (
    name:
    let
      capability = cfg.registry.${name};
    in
    duplicateValues capability.providers
    || duplicateValues capability.backends
    || duplicateValues capability.requiresCapabilities
  ) registryNames;
  unknownCapabilityDependencies = lib.concatMap (
    name:
    map (dependency: "${name}/${dependency}") (
      builtins.filter (
        dependency: !builtins.hasAttr dependency cfg.registry
      ) cfg.registry.${name}.requiresCapabilities
    )
  ) registryNames;
  dependencyClosure =
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
              if builtins.hasAttr name cfg.registry then cfg.registry.${name}.requiresCapabilities else [ ];
          in
          if builtins.elem name visited then
            visit remaining visited
          else
            visit (remaining ++ dependencies) (visited ++ [ name ]);
    in
    visit initial [ ];
  capabilityCycles = builtins.filter (
    name: builtins.elem name (dependencyClosure cfg.registry.${name}.requiresCapabilities)
  ) registryNames;
  enabledClosure = dependencyClosure cfg.enabled;
  enabledRegistryNames = builtins.filter (name: builtins.hasAttr name cfg.registry) enabledClosure;
  enabledCapabilities = map (name: cfg.registry.${name}) enabledRegistryNames;
  enabledProviders = lib.sort builtins.lessThan (
    lib.unique (lib.concatMap (capability: capability.providers) enabledCapabilities)
  );
  enabledBackends = lib.sort builtins.lessThan (
    lib.unique (lib.concatMap (capability: capability.backends) enabledCapabilities)
  );
  allProviders = lib.concatMap (name: cfg.registry.${name}.providers) registryNames;
  allBackends = lib.concatMap (name: cfg.registry.${name}.backends) registryNames;
  duplicateProviderOwners = builtins.filter (
    provider: lib.count (candidate: candidate == provider) allProviders > 1
  ) (lib.unique allProviders);
  duplicateBackendOwners = builtins.filter (
    backend: lib.count (candidate: candidate == backend) allBackends > 1
  ) (lib.unique allBackends);
  skillRegistry = lib.attrByPath [ "dotfiles" "skills" "registry" ] { } config;
  enabledSkills = lib.attrByPath [ "dotfiles" "skills" "enabled" ] [ ] config;
  unknownSkillCapabilities = lib.concatMap (
    name:
    map (capability: "${name}/${capability}") (
      builtins.filter (
        capability: !builtins.hasAttr capability cfg.registry
      ) skillRegistry.${name}.requiresCapabilities
    )
  ) (builtins.attrNames skillRegistry);
  disabledSkillCapabilities = lib.concatMap (
    name:
    if builtins.hasAttr name skillRegistry then
      map (capability: "${name}/${capability}") (
        builtins.filter (
          capability: !builtins.elem capability enabledClosure
        ) skillRegistry.${name}.requiresCapabilities
      )
    else
      [ ]
  ) enabledSkills;
in
{
  options.dotfiles.capabilities = {
    registry = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            implementation = lib.mkOption {
              type = capabilityIdType;
              description = "Capability を実現する implementation ID";
            };
            providers = lib.mkOption {
              type = lib.types.listOf capabilityIdType;
              description = "Capability が有効なとき公開する MCP provider ID";
            };
            backends = lib.mkOption {
              type = lib.types.listOf capabilityIdType;
              description = "Capability が有効なとき配備する container backend ID";
            };
            requiresCapabilities = lib.mkOption {
              type = lib.types.listOf capabilityIdType;
              description = "implementation が必要とする別の Capability ID";
            };
          };
        }
      );
      default = { };
      internal = true;
      description = "consumer 非依存 Capability と implementation の registry";
    };

    enabled = lib.mkOption {
      type = lib.types.listOf capabilityIdType;
      description = "この host で有効にする Capability ID";
    };
  };

  config = {
    dotfiles.platform.mcp.enabledProviders = enabledProviders;
    dotfiles.platform.containers.enabled = enabledBackends;

    assertions = [
      {
        assertion = invalidRegistryNames == [ ];
        message =
          "Capability registry keys must be semantic IDs: " + lib.concatStringsSep ", " invalidRegistryNames;
      }
      {
        assertion = !duplicateEnabled;
        message = "dotfiles.capabilities.enabled must not contain duplicate Capability IDs";
      }
      {
        assertion = unknownEnabled == [ ];
        message = "Unknown enabled Capability IDs: ${lib.concatStringsSep ", " unknownEnabled}";
      }
      {
        assertion = duplicateMetadata == [ ];
        message =
          "Capability metadata lists must not contain duplicates: "
          + lib.concatStringsSep ", " duplicateMetadata;
      }
      {
        assertion = unknownCapabilityDependencies == [ ];
        message =
          "Unknown Capability dependencies: " + lib.concatStringsSep ", " unknownCapabilityDependencies;
      }
      {
        assertion = capabilityCycles == [ ];
        message = "Capability dependency cycles: ${lib.concatStringsSep ", " capabilityCycles}";
      }
      {
        assertion = duplicateProviderOwners == [ ];
        message =
          "MCP providers must have one Capability owner: "
          + lib.concatStringsSep ", " duplicateProviderOwners;
      }
      {
        assertion = duplicateBackendOwners == [ ];
        message =
          "Container backends must have one Capability owner: "
          + lib.concatStringsSep ", " duplicateBackendOwners;
      }
      {
        assertion = unknownSkillCapabilities == [ ];
        message =
          "Skills require unknown Capabilities: " + lib.concatStringsSep ", " unknownSkillCapabilities;
      }
      {
        assertion = disabledSkillCapabilities == [ ];
        message =
          "Enabled Skills require disabled Capabilities: "
          + lib.concatStringsSep ", " disabledSkillCapabilities;
      }
    ];
  };
}
