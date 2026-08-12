{
  helpers,
  lib,
  ...
}@args:

let
  checkDirectory = builtins.readDir ./checks;
  expectedCheckFiles = [
    "client-contract.nix"
    "deployment.nix"
    "installation.nix"
    "resource-lifecycle.nix"
    "runtime.nix"
  ];
  actualCheckFiles = lib.sort builtins.lessThan (
    builtins.filter (lib.hasSuffix ".nix") (builtins.attrNames checkDirectory)
  );
  invalidCheckFileTypes = builtins.filter (
    name: checkDirectory.${name} != "regular"
  ) actualCheckFiles;
  expectedCheckNames = [
    "agent-apm-binary-runs"
    "agent-artifact-contract"
    "agent-client-roster"
    "agent-config-migration"
    "agent-definition-rendering"
    "agent-installer-behavior"
    "agent-nix-build-shims"
    "agent-project-cache-gc"
    "agent-resource-behavior"
    "agent-resource-contract"
    "agent-runtime-behavior"
    "agent-runtime-contract"
    "agent-verification-cache"
    "lsp-registration"
  ];
  checks = helpers.mergeCheckParts [
    (import ./checks/client-contract.nix args)
    (import ./checks/deployment.nix args)
    (import ./checks/installation.nix args)
    (import ./checks/runtime.nix args)
    (import ./checks/resource-lifecycle.nix args)
  ];
in
assert lib.assertMsg (
  invalidCheckFileTypes == [ ]
) "agent check parts must be regular files: ${builtins.toJSON invalidCheckFileTypes}";
assert lib.assertMsg (actualCheckFiles == expectedCheckFiles)
  "agent check part roster mismatch: ${
    builtins.toJSON {
      actual = actualCheckFiles;
      expected = expectedCheckFiles;
    }
  }";
assert lib.assertMsg (builtins.attrNames checks == expectedCheckNames)
  "agent check id roster mismatch: ${
    builtins.toJSON {
      actual = builtins.attrNames checks;
      expected = expectedCheckNames;
    }
  }";
checks
