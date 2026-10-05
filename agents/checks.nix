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
    "runtime.nix"
  ];
  actualCheckFiles = lib.sort builtins.lessThan (
    builtins.filter (lib.hasSuffix ".nix") (builtins.attrNames checkDirectory)
  );
  invalidCheckFileTypes = builtins.filter (
    name: checkDirectory.${name} != "regular"
  ) actualCheckFiles;
  expectedCheckNames = [
    "agent-artifact-contract"
    "agent-capability-gating"
    "agent-claude-managed-policy"
    "agent-client-roster"
    "agent-client-selection"
    "agent-config-migration"
    "agent-installer-behavior"
    "agent-nix-build-shims"
    "agent-project-cache-gc"
    "agent-runtime-behavior"
    "agent-runtime-contract"
    "agent-subagent-rendering"
    "agent-verification-cache"
    "lsp-registration"
  ];
  checks = helpers.mergeCheckParts [
    (import ./checks/client-contract.nix args)
    (import ./checks/deployment.nix args)
    (import ./checks/installation.nix args)
    (import ./checks/runtime.nix args)
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
