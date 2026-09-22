{
  lib,
  pkgs,
  hostConfig,
  ...
}:

let
  runtime = hostConfig.dotfiles.capabilities.project-memory.runtime.override {
    apiUrl = "http://127.0.0.1:18082";
  };
  integrations = pkgs.callPackage ./package.nix { inherit runtime; };
in
{
  project-memory-client-integrations =
    pkgs.runCommandLocal "check-project-memory-client-integrations"
      {
        nativeBuildInputs = [
          pkgs.bun
          pkgs.git
        ];
      }
      ''
        export MEMORY_BINARY=${lib.getExe runtime}
        export MEMORY_PLUGIN=${integrations.opencodePlugin}
        bun test ${./checks}
        touch "$out"
      '';
}
