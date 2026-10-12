{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled =
    builtins.elem "security-assessment" config.dotfiles.capabilities.resolved
    && config.dotfiles.capabilities.registry."security-assessment".implementation == "strix";
  mkCommand = import ../../../../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
  native = pkgs.callPackage ./package.nix { };
  image = "ghcr.io/usestrix/strix-sandbox:1.3.0@sha256:e5e5d9927f15ca95ad49804ef7d22439771cd27378f400da6edd47556799baff";
  runtime = mkCommand {
    name = "strix";
    src = ./package/entry.sh;
    runtimeInputs = with pkgs; [
      coreutils
      docker
      git
    ];
    vars = {
      upstream = lib.getExe native;
      goApiKeyFile = lib.escapeShellArg config.sops.secrets."opencode/go_api_key".path;
      inherit image;
    };
    extra = {
      meta.mainProgram = "strix";
      passthru = {
        inherit native image;
        commandSmokeTimeoutArgs = [
          "--kill-after=2s"
          "20s"
        ];
      };
    };
  };
  runtimeOperations = mkCommand {
    name = "dotfiles-strix-runtime";
    src = ./package/runtime.sh;
    runtimeInputs = with pkgs; [
      docker
      jq
    ];
    extra.meta.mainProgram = "dotfiles-strix-runtime";
  };
in
{
  options.dotfiles.capabilities.security-assessment.runtime = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
  };

  config = lib.mkIf enabled {
    dotfiles.capabilities.security-assessment.runtime = runtime;
    dotfiles.platform.cli.commands.strix = runtime;
    dotfiles.platform.cli.commands.strixRuntime = runtimeOperations;
    dotfiles.platform.containers.runtimeImages.strix = image;
    sops.secrets."opencode/go_api_key" = {
      mode = "0400";
      owner = config.dotfiles.workstation.username;
      group = "users";
    };
  };
}
