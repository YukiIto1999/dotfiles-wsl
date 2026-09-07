{ config, ... }:

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

    skills.enabled = builtins.attrNames config.dotfiles.skills.registry;

    capabilities.enabled = [
      "agent-session"
      "browser-automation"
      "browser-diagnostics"
      "browser-runtime"
      "code-quality"
      "github-resources"
      "library-documentation"
      "project-memory"
      "repository-search"
      "web-content"
      "web-discovery"
    ];
  };
}
