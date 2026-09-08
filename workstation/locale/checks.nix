{
  pkgs,
  hostConfig,
  ...
}:

{
  # zone 名と locale 名の誤りは eval も activation も落とさず、UTC と C への無言の
  # fallback になる。宣言そのものを読み返しても検出できないため、実際の書式で固定する
  host-locale-contract =
    pkgs.runCommandLocal "check-host-locale-contract"
      {
        # glibcLocales は build tool ではなく、setup hook が生成済み archive を渡すために置く
        nativeBuildInputs = [
          pkgs.coreutils
          hostConfig.i18n.glibcLocales
        ];
        timeZone = hostConfig.time.timeZone;
        defaultLocale = hostConfig.i18n.defaultLocale;
        zoneinfo = "${pkgs.tzdata}/share/zoneinfo";
      }
      ''
        set -euo pipefail

        expected='1970-01-01 09:00 JST 木曜日'
        actual=$(TZDIR="$zoneinfo" TZ="$timeZone" LC_ALL="$defaultLocale" \
          date --date=@0 '+%Y-%m-%d %H:%M %Z %A')
        if [ "$actual" != "$expected" ]; then
          echo "declared time zone and locale do not render JST in Japanese:" >&2
          echo "  expected: $expected" >&2
          echo "  actual:   $actual" >&2
          exit 1
        fi
        touch $out
      '';
}
