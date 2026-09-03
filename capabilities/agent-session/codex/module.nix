{ config, lib, ... }:

let
  runtime = config.dotfiles.capabilities.agent-session.codex.runtime;
in
{
  options.dotfiles.capabilities.agent-session.codex.runtime = {
    binary = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    executable = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    install = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      description = "Agents ownerが検証して実行するCodex配備contract。";
    };
  };

  config.dotfiles.capabilities.agent-session.codex.runtime = {
    binary = "codex";
    executable = "${config.dotfiles.workstation.homeDir}/.local/bin/${runtime.binary}";
    install = {
      kind = "github-release";
      updateOwner = "dotfiles";
      layout = "package-tree";
      repo = "openai/codex";
      retainedReleases = 2;
      releaseByArch = {
        x86_64 = {
          asset = "codex-package-x86_64-unknown-linux-musl.tar.gz";
          entrypoint = "bin/codex";
        };
        aarch64 = {
          asset = "codex-package-aarch64-unknown-linux-musl.tar.gz";
          entrypoint = "bin/codex";
        };
      };
      requiredPaths = {
        "bin/codex" = {
          kind = "file";
          executable = true;
        };
        "codex-package.json" = {
          kind = "file";
          executable = false;
        };
        "bin/codex-code-mode-host" = {
          kind = "file";
          executable = true;
        };
        "codex-path/rg" = {
          kind = "file";
          executable = true;
        };
        "codex-resources/bwrap" = {
          kind = "file";
          executable = true;
        };
      };
    };
  };
}
