{
  helpers,
  lib,
  pkgs,
  hostConfig,
  ...
}:

let
  template = hostConfig.my.artifacts."mcp/searxng/settings-template".source;

  # 契約の写しと突き合わせても、同じ宣言の二つの写しが一致するだけ。
  # 実際に配備される argv から container 側の port を取る
  published = helpers.execTokens.valuesOf helpers.containerArgv.containerArgv.searxng "-p";
  containerPort = lib.last (lib.splitString ":" (builtins.head published));
in
{
  # settings は secret template として実配備へ渡る。値の一致は生成側で見る
  searxng-settings =
    assert hostConfig.sops.templates."searxng-settings.yml".content == builtins.readFile template;
    assert builtins.length published == 1;
    pkgs.runCommandLocal "check-searxng-settings" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      test "$(yq -r '.server.port' ${template})" = ${containerPort}
      touch $out
    '';
}
