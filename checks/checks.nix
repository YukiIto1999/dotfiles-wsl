{
  helpers,
  lib,
  ...
}@args:

let
  checkDirectory = builtins.readDir ./checks;
  expectedCheckFiles = [
    "documentation.nix"
    "repository-structure.nix"
    "runtime-registry.nix"
    "static-analysis.nix"
    "unit-boundaries.nix"
  ];
  actualCheckFiles = lib.sort builtins.lessThan (
    builtins.filter (lib.hasSuffix ".nix") (builtins.attrNames checkDirectory)
  );
  invalidCheckFileTypes = builtins.filter (
    name: checkDirectory.${name} != "regular"
  ) actualCheckFiles;
  expectedCheckNames = [
    "actionlint"
    "deadnix"
    "development-tool-ownership"
    "docs-constraint-coverage"
    "docs-links"
    "docs-path-labels"
    "docs-reader"
    "dotfiles-option-namespace"
    "loopback-port-single-owner"
    "nixfmt"
    "option-namespace"
    "registries-non-empty"
    "required-roster-negative-eval"
    "runtime-identity"
    "service-listener-registry"
    "shellcheck"
    "statix"
    "structure-layer-names"
    "structure-responsibility-roots"
    "structure-unit-directory-names"
    "toolchain-single-owner"
    "unit-boundary-name-only"
    "unit-module-marker"
  ];
  checks = helpers.mergeCheckParts [
    (import ./checks/repository-structure.nix args)
    (import ./checks/runtime-registry.nix args)
    (import ./checks/unit-boundaries.nix args)
    (import ./checks/documentation.nix args)
    (import ./checks/static-analysis.nix args)
  ];
in
assert lib.assertMsg (
  invalidCheckFileTypes == [ ]
) "cross-unit check parts must be regular files: ${builtins.toJSON invalidCheckFileTypes}";
assert lib.assertMsg (actualCheckFiles == expectedCheckFiles)
  "cross-unit check part roster mismatch: ${
    builtins.toJSON {
      actual = actualCheckFiles;
      expected = expectedCheckFiles;
    }
  }";
assert lib.assertMsg (builtins.attrNames checks == expectedCheckNames)
  "cross-unit check id roster mismatch: ${
    builtins.toJSON {
      actual = builtins.attrNames checks;
      expected = expectedCheckNames;
    }
  }";
checks
