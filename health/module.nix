{
  config,
  lib,
  pkgs,
  ...
}:

let
  registry = config.dotfiles.health.observations;
  projectObservation = key: observation: {
    inherit key;
    value = lib.mapAttrs (
      name: value: if name == "command" then lib.getExe value else value
    ) observation;
  };
  observations = lib.sort (left: right: left.key < right.key) (
    lib.mapAttrsToList projectObservation registry
  );

  normalizedRows = builtins.filter (row: row.value.kind == "normalized-protocol") observations;
  directRows = builtins.filter (row: row.value.kind != "normalized-protocol") observations;
  checkIds = map (row: row.value.checkId) observations;
  directCheckIds = map (row: row.value.checkId) directRows;
  fallbackCheckIds = map (row: row.value.checkId) normalizedRows;
  allowedIdsFor = row: row.value.allowedOutcomeIds;
  normalizedIdsDoNotCollide = lib.all (
    row:
    let
      otherFallbackIds = builtins.filter (id: id != row.value.checkId) fallbackCheckIds;
      otherAllowedIds = lib.concatMap allowedIdsFor (
        builtins.filter (other: other.key != row.key) normalizedRows
      );
      forbidden = directCheckIds ++ otherFallbackIds ++ otherAllowedIds;
    in
    lib.all (id: !builtins.elem id forbidden) row.value.allowedOutcomeIds
  ) normalizedRows;

  directResourceKeys = builtins.filter (key: key != null) (
    map (row: row.value.resourceKey) directRows
  );
  normalizedResourceKeys = lib.concatMap (row: row.value.requiredResourceKeys) normalizedRows;
  aggregateResourceKeys = [
    "containerRestarts"
    "serviceRestarts"
  ];
  resourceKeys = directResourceKeys ++ normalizedResourceKeys ++ aggregateResourceKeys;
  normalizedFallbackResourcesMatch = lib.all (
    row:
    row.value.resourceKey == null || builtins.elem row.value.resourceKey row.value.requiredResourceKeys
  ) normalizedRows;

  doctor = import ./package.nix {
    inherit pkgs lib observations;
  };
in
{
  imports = [ ./impl/observation-registry.nix ];

  config = {
    assertions = [
      {
        assertion = lib.all (id: id != null) checkIds;
        message = "every production observation must declare a checkId";
      }
      {
        assertion = checkIds == lib.unique checkIds;
        message = "production observation fallback check IDs must be unique";
      }
      {
        assertion = normalizedIdsDoNotCollide;
        message = "normalized protocol outcome IDs must not collide with another observation contract";
      }
      {
        assertion = normalizedFallbackResourcesMatch;
        message = "normalized protocol fallback resourceKey must belong to its required resource set";
      }
      {
        assertion = resourceKeys == lib.unique resourceKeys;
        message = "runtime observation resource producers must be unique";
      }
    ];
    dotfiles.platform.cli.commands = { inherit doctor; };
  };
}
