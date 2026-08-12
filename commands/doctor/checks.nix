{
  helpers,
  lib,
  ...
}@args:

let
  checkDirectory = builtins.readDir ./checks;
  expectedCheckFiles = [
    "registry.nix"
    "runtime.nix"
  ];
  actualCheckFiles = lib.sort builtins.lessThan (
    builtins.filter (lib.hasSuffix ".nix") (builtins.attrNames checkDirectory)
  );
  invalidCheckFileTypes = builtins.filter (
    name: checkDirectory.${name} != "regular"
  ) actualCheckFiles;
  expectedCheckNames = [
    "doctor-coverage"
    "doctor-runtime"
  ];
  checks = helpers.mergeCheckParts [
    (import ./checks/registry.nix args)
    (import ./checks/runtime.nix args)
  ];
in
assert lib.assertMsg (
  invalidCheckFileTypes == [ ]
) "doctor check parts must be regular files: ${builtins.toJSON invalidCheckFileTypes}";
assert lib.assertMsg (actualCheckFiles == expectedCheckFiles)
  "doctor check part roster mismatch: ${
    builtins.toJSON {
      actual = actualCheckFiles;
      expected = expectedCheckFiles;
    }
  }";
assert lib.assertMsg (builtins.attrNames checks == expectedCheckNames)
  "doctor check id roster mismatch: ${
    builtins.toJSON {
      actual = builtins.attrNames checks;
      expected = expectedCheckNames;
    }
  }";
checks
