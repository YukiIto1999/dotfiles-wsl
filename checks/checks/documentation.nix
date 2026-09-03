{
  pkgs,
  self,
  allCheckNames,
  ...
}:

{
  docs-reader = pkgs.runCommandLocal "check-docs-reader" { } ''
    set -euo pipefail
    missing=""
    for kind in operations reference architecture; do
      for doc in ${self}/docs/$kind/*.md; do
        grep -q '^\*\*読み手:\*\*' "$doc" || missing="$missing $doc"
      done
    done
    if [ -n "$missing" ]; then
      echo "docs missing a reader statement:$missing" >&2
      exit 1
    fi
    touch $out
  '';

  # 固定した制約の一覧が実際の check 集合と一致する
  docs-constraint-coverage =
    pkgs.runCommandLocal "check-docs-constraint-coverage"
      {
        checkNames = allCheckNames;
      }
      ''
        set -euo pipefail
        list=${self}/docs/reference/verified-constraints.md

        # 文書のどこかに名前があれば通る形だと、制約行と対応していなくても
        # 緑になる。表の最終列だけを対応表として読む
        awk -F '|' '/^\|/ { print $(NF - 1) }' "$list" \
          | grep -o '`[a-z][a-z0-9-]*`' | tr -d '`' | sort -u > documented

        undocumented=""
        for name in $checkNames; do
          grep -qFx "$name" documented || undocumented="$undocumented $name"
        done
        if [ -n "$undocumented" ]; then
          echo "checks missing from the verified constraint list:$undocumented" >&2
          exit 1
        fi

        stale=""
        for name in $(awk -F '|' '/^\|/ { print $(NF - 1) }' "$list" \
          | grep -o '`[a-z][a-z0-9-]*`' | tr -d '`' | sort -u); do
          case " $checkNames " in
            *" $name "*) ;;
            *) stale="$stale $name" ;;
          esac
        done
        if [ -n "$stale" ]; then
          echo "verified constraint list names a check that does not exist:$stale" >&2
          exit 1
        fi

        touch $out
      '';

  # 文書の相互参照。移動と参照切れを build で落とす
  docs-links = pkgs.testers.lycheeLinkCheck {
    # 文書は宣言 file を参照するため、site は checkout 全体にする
    site = self;
    extraConfig.offline = true;
  };

  # link 先が解決しても、表示名が移動前の path を名乗っていれば読み手は迷う。
  # link destination だけでなく、表示した repository path の実在も検査する。
  docs-path-labels =
    pkgs.runCommandLocal "check-docs-path-labels"
      {
        nativeBuildInputs = with pkgs; [
          coreutils
          gnugrep
          gnused
        ];
      }
      ''
        set -euo pipefail

        missing=""
        while IFS= read -r doc; do
          # 大文字を含む token は NAME のような雛形なので対象にしない
          while IFS= read -r label; do
            [ -e "${self}/$label" ] || missing="$missing ''${doc#${self}/}:$label"
          done < <(
            grep -ohE '`[a-z0-9_.-]+/[a-z0-9_./-]+\.(nix|sh|md|yaml|yml|json|py|ts)`' "$doc" \
              | tr -d '`' | sort -u || true
          )
        done < <(find ${self}/README.md ${self}/CONTRIBUTING.md ${self}/docs -name '*.md')

        if [ -n "$missing" ]; then
          echo "documentation names a path that does not exist:$missing" >&2
          exit 1
        fi
        touch $out
      '';

}
