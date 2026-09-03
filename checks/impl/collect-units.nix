{
  lib,
  readDir ? builtins.readDir,
}:
root:
let
  walk =
    prefix: path:
    let
      entries = readDir path;
      directories = lib.filterAttrs (_: kind: kind == "directory") entries;
      children = lib.concatMap (name: walk "${prefix}/${name}" (path + "/${name}")) (
        builtins.attrNames directories
      );
    in
    lib.optional ((entries."module.nix" or null) == "regular") {
      id = prefix;
      inherit path;
    }
    ++ children;

  directories = lib.filterAttrs (_: kind: kind == "directory") (readDir root);
in
lib.concatMap (name: walk name (root + "/${name}")) (builtins.attrNames directories)
