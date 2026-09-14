_:

{
  dotfiles = {
    workstation = { };

    toolchain = {
      enabledLsp = [
        "bash"
        "csharp"
        "java"
        "nix"
        "python"
        "rust"
        "typescript"
      ];
      git.workIdentity = "~/projects/business/";
    };

    agents.enabled = [
      "antigravity"
      "claude"
      "codex"
      "omp"
      "opencode"
    ];

    capabilities.enabled = [
      "browser-automation"
      "browser-diagnostics"
      "browser-runtime"
      "github-resources"
      "library-documentation"
      "repository-search"
    ];
  };
}
