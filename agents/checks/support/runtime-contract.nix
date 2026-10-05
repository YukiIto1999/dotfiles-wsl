{ homeDir }:

let
  expectedAgentRuntime = {
    cache = {
      root = "${homeDir}/.cache/dotfiles-wsl";
      cargoBuildRoot = "${homeDir}/.cache/dotfiles-wsl/cargo-build";
      sharedRoot = "${homeDir}/.cache/dotfiles-wsl/shared";
      sessionsRoot = "${homeDir}/.cache/dotfiles-wsl/sessions";
      verificationRoot = "${homeDir}/.cache/dotfiles-wsl/verification";
      highBytes = 68719476736;
      lowBytes = 51539607552;
      inactiveDays = 30;
    };
    state = {
      root = "${homeDir}/.local/state/dotfiles-wsl";
    };
    timers = {
      autoupdate = {
        name = "dotfiles-agent-autoupdate";
        onCalendar = "daily";
        persistent = true;
      };
      projectCacheGc = {
        name = "dotfiles-agent-project-cache-gc";
        onCalendar = "daily";
        persistent = true;
      };
    };
  };
  runtimePackageContract = expectedAgentRuntime // {
    cache = expectedAgentRuntime.cache // {
      relativeCacheRoot = ".cache/dotfiles-wsl";
    };
    sliceUnit = "agents.slice";
  };
in
{
  inherit expectedAgentRuntime runtimePackageContract;
}
