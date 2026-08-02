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
  # 部分一致も存在確認も追記で破れる。argparse も env も後勝ちなので、
  # 出現回数を数え、--flag value と --flag=value の両形を見る
  valuesOf =
    tokens: flag:
    lib.concatLists (
      lib.imap0 (
        index: token:
        lib.optional (token == flag && index + 1 < builtins.length tokens) (
          builtins.elemAt tokens (index + 1)
        )
        ++ lib.optional (lib.hasPrefix "${flag}=" token) (lib.removePrefix "${flag}=" token)
      ) tokens
    );

  onlyValue =
    tokens: flag: expected:
    valuesOf tokens flag == [ expected ];

  boundElsewhere = builtins.filter (
    front:
    let
      tokens = builtins.filter (token: token != "") (lib.splitString " " (configOf front).ExecStart);
      port = toString front.port;
      viaOption = onlyValue tokens "--host" "127.0.0.1" && onlyValue tokens "--port" port;
      viaEnvironment =
        onlyValue tokens "MCP_HTTP_HOST" "127.0.0.1" && onlyValue tokens "MCP_HTTP_PORT" port;
    in
    !(viaOption || viaEnvironment)
  ) fronts;

  # 外へ出る front を増やす変更は必ず diff に現れる。宣言だけで制限は外せない
  expectedNetworkFronts = [
    "codex"
    "context7"
    "github-account-1"
    "github-account-2"
    "github-account-3"
    "playwright"
    "searxng"
  ];

  actualNetworkFronts = lib.sort builtins.lessThan (
    builtins.attrNames (lib.filterAttrs (_: target: target.needsNetwork) targets)
  );

  # needsNetwork を宣言しない front は、通信が loopback へ限られていること
  unrestricted = builtins.filter (
    front:
    !targets.${front.name}.needsNetwork
    && (
      (configOf front).IPAddressDeny or null != "any"
      || (configOf front).IPAddressAllow or null != "localhost"
    )
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
    assert unrestricted == [ ];
    assert actualNetworkFronts == expectedNetworkFronts;
    pkgs.runCommandLocal "check-mcp-front-contract" { } "touch $out";
}
