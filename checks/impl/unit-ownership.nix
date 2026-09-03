{ lib }:

{
  resolveUnitOwner =
    units: relativeFile:
    lib.foldl' (
      owner: unit:
      let
        ownsFile = relativeFile == unit.id || lib.hasPrefix "${unit.id}/" relativeFile;
        isCloserOwner = owner == null || builtins.stringLength unit.id > builtins.stringLength owner.id;
      in
      if ownsFile && isCloserOwner then unit else owner
    ) null units;
}
