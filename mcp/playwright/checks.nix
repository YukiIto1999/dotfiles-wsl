{
  helpers,
  pkgs,
  hostConfig,
  ...
}:

let
  inherit (helpers.execTokens) tokensOf onlyValue;
  front = hostConfig.dotfiles.mcp.fronts.playwright;
  service = hostConfig.systemd.services.${front.service}.serviceConfig;
  tokens = tokensOf service.ExecStart;
in
{
  playwright-front =
    assert front.url == "http://127.0.0.1:${toString front.port}/mcp";
    # 生成物は service の runtime directory に閉じる。HOME へ書かせない
    assert onlyValue tokens "--output-dir" front.runtimeDirectoryPath;
    assert service.RuntimeDirectory == front.runtimeDirectory;
    pkgs.runCommandLocal "check-playwright-front" { } "touch $out";
}
