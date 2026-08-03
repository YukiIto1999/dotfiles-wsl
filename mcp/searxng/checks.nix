{
  pkgs,
  hostConfig,
  ...
}:

let
  template = hostConfig.my.artifacts."mcp/searxng/settings-template".source;
in
{
  # settings は secret template として実配備へ渡る。値の一致は生成側で見る
  searxng-settings =
    assert hostConfig.sops.templates."searxng-settings.yml".content == builtins.readFile template;
    pkgs.runCommandLocal "check-searxng-settings" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      test "$(yq -r '.server.port' ${template})" = ${hostConfig.my.contract.searxng.port}
      touch $out
    '';
}
