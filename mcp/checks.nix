{
  pkgs,
  lib,
  self,
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
  inherit (import "${self}/mcp/impl/exec-tokens.nix" { inherit lib; })
    tokensOf
    onlyValue
    ;

  boundElsewhere = builtins.filter (
    front:
    let
      tokens = tokensOf (configOf front).ExecStart;
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

  # unit の ExecStart しか見ないと、wrapper が後から bind を上書きできる。
  # binary は Nix から読めないので、shebang の判定は derivation の中で行う
  mcp-front-wrapper-bind =
    let
      execs = map (front: services.${front.service}.serviceConfig.ExecStart) fronts;
    in
    pkgs.runCommandLocal "check-mcp-front-wrapper-bind" { } ''
      inspected=0

      # 引用を外してから見る。--ho"st" は shell では --host に戻る
      inspect() {
        [ "$(head -c 2 "$1")" = '#!' ] || return 0
        inspected=$((inspected + 1))
        norm=$(tr -d '"'"'"'"\\' < "$1")
        if printf '%s' "$norm" | grep -qE -- '--host|--port|--allowed-hosts|--output-dir|MCP_HTTP_HOST|MCP_HTTP_PORT'; then
          echo "front wrapper decides its own bind: $1"
          exit 1
        fi
        # exec で辿り着く先も wrapper。一段の間接で消えないようにする
        for next in $(printf '%s' "$norm" | sed -n 's/^ *exec \([^ ]*\).*/\1/p'); do
          case "$next" in /nix/store/*) [ -f "$next" ] && inspect "$next" ;; esac
        done
      }

      # 総数を固定すると上流の packaging で壊れる。front ごとに一つ以上見る
      for exec in ${lib.escapeShellArgs execs}; do
        inspected=0
        for token in $exec; do
          case "$token" in /nix/store/*) ;; *) continue ;; esac
          [ -f "$token" ] || continue
          inspect "$token"
        done
        test "$inspected" -ge 1 || { echo "no wrapper inspected for: $exec"; exit 1; }
      done
      touch $out
    '';
}
