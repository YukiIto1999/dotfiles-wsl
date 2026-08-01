{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  fronts = builtins.attrValues hostConfig.my.contract.mcp.fronts;
  services = hostConfig.systemd.services;
  targets = hostConfig.my.mcp.targets;
  configOf = front: services.${front.service}.serviceConfig;

  # typo した wait 先は systemd が黙って無視するので、宣言時に実在を確かめる
  missingWaits = lib.concatMap (
    front:
    builtins.filter (
      unit: !(services ? ${lib.removeSuffix ".service" unit})
    ) targets.${front.name}.waitUnits
  ) fronts;

  # front が loopback を外れると、firewall の無い WSL では外部から到達しうる。
  # bind 先を宣言から読めるのは proxy 経由の形だけなので、それ以外は
  # 自分で loopback を指定していることを起動 command に要求する
  boundElsewhere = builtins.filter (
    front:
    let
      exec = (configOf front).ExecStart;
      port = toString front.port;
      # 起動 command に bind 先が現れることを要求する。option でしか受けない
      # front も、module が env として command に載せる
      viaOption = lib.hasInfix "--host 127.0.0.1" exec && lib.hasInfix "--port ${port}" exec;
      viaEnvironment =
        lib.hasInfix "MCP_HTTP_HOST=127.0.0.1" exec && lib.hasInfix "MCP_HTTP_PORT=${port}" exec;
    in
    !(viaOption || viaEnvironment)
  ) fronts;
in
{
  # front は宣言した port で loopback に listen し、書き込み領域を持つ
  mcp-front-contract =
    assert fronts != [ ];
    assert lib.all (front: (configOf front).RuntimeDirectory == front.runtimeDirectory) fronts;
    assert lib.all (front: (configOf front).RuntimeDirectoryMode == "0700") fronts;
    assert lib.all (front: (configOf front).User == hostConfig.my.username) fronts;
    assert missingWaits == [ ];
    assert boundElsewhere == [ ];
    pkgs.runCommandLocal "check-mcp-front-contract" { } "touch $out";
}
