{
  helpers,
  lib,
  ...
}@args:

let
  checkDirectory = builtins.readDir ./checks;
  expectedCheckFiles = [
    "observation-contract.nix"
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
    "observation-contract"
  ];
  checks = helpers.mergeCheckParts [
    (import ./checks/observation-contract.nix args)
    (import ./checks/registry.nix args)
    (import ./checks/runtime.nix args)
  ];
in
assert lib.assertMsg (
  invalidCheckFileTypes == [ ]
) "health check parts must be regular files: ${builtins.toJSON invalidCheckFileTypes}";
assert lib.assertMsg (actualCheckFiles == expectedCheckFiles)
  "health check part roster mismatch: ${
    builtins.toJSON {
      actual = actualCheckFiles;
      expected = expectedCheckFiles;
    }
  }";
assert lib.assertMsg (builtins.attrNames checks == expectedCheckNames)
  "health check id roster mismatch: ${
    builtins.toJSON {
      actual = builtins.attrNames checks;
      expected = expectedCheckNames;
    }
  }";
checks
