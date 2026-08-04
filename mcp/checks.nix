{
  helpers,
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
  # 全 front が mcp-proxy の前段を通るので、bind 先は起動 command に現れる
  inherit (helpers.execTokens)
    tokensOf
    onlyValue
    ;

  boundElsewhere = builtins.filter (
    front:
    let
      tokens = tokensOf (configOf front).ExecStart;
      port = toString front.port;
    in
    !(onlyValue tokens "--host" "127.0.0.1" && onlyValue tokens "--port" port)
  ) fronts;

  # 外へ出る front を増やす変更は必ず diff に現れる。宣言だけで制限は外せない
  expectedNetworkFronts = [
    "codex"
    "context7"
    "github-account-1"
    "github-account-2"
    "github-account-3"
    "playwright"
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
    # 片方だけ増減すると、宣言した target が front を持たないまま緑になる
    assert map (front: front.name) fronts == builtins.attrNames targets;
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

  # 生成した wrapper が実際に起動するかは、宣言の整合では見えない。
  # exec の位置を誤ると起動せず、それでも 40 の check は緑を返す
  mcp-front-starts =
    let
      # stdio front は mcp-proxy に包まれる前の実体を直接起こす
      execs = map (front: services.${front.service}.serviceConfig.ExecStart) fronts;
    in
    pkgs.runCommandLocal "check-mcp-front-starts"
      {
        nativeBuildInputs = with pkgs; [
          coreutils
          gnugrep
          gnused
        ];
      }
      ''
        set -euo pipefail

        # 継続行を畳んでから見る。危険な書き方を数え上げても必ず漏れるので、
        # 「exec は唯一で、単純コマンドで、最後の実行文」という安全な形を要求する
        inspect() {
          script=$1
          ${pkgs.bash}/bin/bash -n "$script" || {
            echo "front wrapper is not valid shell: $script" >&2
            exit 1
          }

          logical=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$script" \
            | grep -vE '^[[:space:]]*(#|$)')

          count=$(printf '%s\n' "$logical" | grep -cE '^[[:space:]]*exec[[:space:]]' || true)
          if [ "$count" != 1 ]; then
            echo "front wrapper must exec exactly once, found $count: $script" >&2
            exit 1
          fi

          if ! printf '%s\n' "$logical" | tail -1 | grep -qE '^[[:space:]]*exec[[:space:]]'; then
            echo "front wrapper runs a command after exec: $script" >&2
            exit 1
          fi

          # 制御演算子を含めば単純コマンドではない。exec が条件に従属しうる
          if printf '%s\n' "$logical" | tail -1 | grep -qE '(&&|\|\||;|\||&)'; then
            echo "front wrapper conditions its exec: $script" >&2
            exit 1
          fi
        }

        started=0
        for exec in ${lib.escapeShellArgs execs}; do
          for token in $exec; do
            case "$token" in /nix/store/*) ;; *) continue ;; esac
            [ -f "$token" ] || continue
            [ "$(head -c 2 "$token")" = '#!' ] || continue
            inspect "$token"
            started=$((started + 1))
          done
        done
        test "$started" -ge ${toString (builtins.length fronts)}
        touch $out
      '';
}
