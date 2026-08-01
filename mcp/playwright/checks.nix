{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  agentgatewayService = hostConfig.systemd.services.agentgateway.serviceConfig;

  # front を上流 binary から切り離し、runtime directory の受け渡しだけを観測する
  fakeChromium = pkgs.writeShellScriptBin "chromium" (builtins.readFile ./fixtures/chromium.sh);
  fakePlaywright = pkgs.writeShellApplication {
    name = "playwright-mcp";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./fixtures/playwright-mcp.sh;
  };
  front = pkgs.callPackage ./package.nix {
    mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
    chromium = fakeChromium;
    playwrightMcp = fakePlaywright;
  };
in
{
  playwright-runtime =
    assert (agentgatewayService.RuntimeDirectory or null) == "agentgateway";
    assert (agentgatewayService.RuntimeDirectoryMode or null) == "0700";
    assert lib.elem "PLAYWRIGHT_MCP_RUNTIME_DIR=/run/agentgateway" agentgatewayService.Environment;
    pkgs.runCommandLocal "check-playwright-runtime"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
        ];
      }
      ''
        bash ${./tests/playwright-runtime.sh} \
          ${lib.getExe front} \
          ${hostConfig.my.mcp.targets.playwright.transport.stdio.command}
        touch $out
      '';
}
