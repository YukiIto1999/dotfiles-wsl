{ pkgs }:

let
  model = "opencode-go/deepseek-v4.1-flash";
  fallback = "commandcode/deepseek/deepseek-v4.1-flash";
  thinking = "low";
  modelRouting = (pkgs.formats.yaml { }).generate "omp-session-job-routing.yml" {
    enabledProviders = [
      "opencode-go"
      "commandcode"
    ];
    enabledModels = [
      model
      fallback
    ];
    advisor.enabled = false;
    retry = {
      enabled = true;
      modelFallback = true;
      fallbackOn = "any";
      maxRetries = 1;
      maxDelayMs = 1000;
      rateLimitWalksChain = true;
      waitForUsageReset = false;
      usageAwareFallback = false;
      fallbackChains = {
        "${model}:${thinking}" = [ "${fallback}:${thinking}" ];
        "${fallback}:${thinking}" = [ ];
        default = [ ];
      };
    };
  };
in
{
  inherit model thinking;
  modelRouting = toString modelRouting;
}
