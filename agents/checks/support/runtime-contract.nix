{ homeDir }:

let
  expectedAgentRuntime = {
    ledgerRetentionDays = 30;
    cache = {
      root = "${homeDir}/.cache/dotfiles-wsl";
      buildsRoot = "${homeDir}/.cache/dotfiles-wsl/builds";
      sharedRoot = "${homeDir}/.cache/dotfiles-wsl/shared";
      sessionsRoot = "${homeDir}/.cache/dotfiles-wsl/sessions";
      verificationRoot = "${homeDir}/.cache/dotfiles-wsl/verification";
      highBytes = 68719476736;
      lowBytes = 51539607552;
      inactiveDays = 30;
    };
    state = {
      root = "${homeDir}/.local/state/dotfiles-wsl";
      resourcesRoot = "${homeDir}/.local/state/dotfiles-wsl/agent-resources";
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
      resourceReaper = {
        name = "dotfiles-agent-resource-reaper";
        onCalendar = "hourly";
        persistent = true;
      };
    };
  };
  runtimePackageContract = expectedAgentRuntime // {
    cache = expectedAgentRuntime.cache // {
      relativeCacheRoot = ".cache/dotfiles-wsl";
    };
    state = expectedAgentRuntime.state // {
      relativeStateRoot = ".local/state/dotfiles-wsl";
      relativeResourcesRoot = ".local/state/dotfiles-wsl/agent-resources";
    };
  };
in
{
  inherit expectedAgentRuntime runtimePackageContract;
}
