{ lib, pkgs }:
/**
  architecture-standard の原版を開く native 入口の共通 directory
  sources: 入口へ置き換える Skill ID と host が審査した原版 source の対応
  command: 原版を開く resolver。入口は同じホスト世代の不変な実行パスを持つ
  戻り値: Skill ID ごとに原版の frontmatter と開き方だけを持つ SKILL.md を置いた一つの store directory
*/
{ sources, command }:
let
  # 一つの標準の仕事は一つの root を使い、その root からは host が原版のまま採用した ID だけを読む
  adopted = lib.concatMapStringsSep "、" (name: "`${name}`") (builtins.attrNames sources);
  bodyFor =
    id:
    pkgs.writeText "standard-route-${id}.md" ''

      # ${id}

      標準の仕事を新しく始めるときだけ `${lib.getExe command} open ${id}` を一度実行し、標準出力が示す原版の `SKILL.md` を読んで従う。原版の `<skill-package-root>` はその file の directory である。
      その path から `skills/${id}/SKILL.md` を除いた directory がこの仕事の root である。同じ仕事の続き、再開、handoff は原版の path を引き継ぎ、`open` を繰り返さない。この root から読む Skill は ${adopted} に限る。
      コマンドを実行できない委譲先には親が解決済みの原版を渡す。未解決なら親に依頼し、権限を増やさない。
      `open` が失敗したら stderr を報告し、この標準の仕事だけを止める。この入口や別の写しで原版を代用しない。
    '';
in
pkgs.runCommandLocal "standard-skill-routes"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.gawk
    ];
  }
  ''
    set -euo pipefail
    mkdir "$out"

    # frontmatter は原版の行をそのまま写し、名前、description、起動 flag を入口で作り直さない
    route() {
      local id=$1 original=$2 body=$3 closing
      test "$(head -n 1 "$original")" = '---'
      closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$original")
      test -n "$closing"
      mkdir "$out/$id"
      cat <(head -n "$closing" "$original") "$body" > "$out/$id/SKILL.md"
    }

    ${lib.concatStrings (
      lib.mapAttrsToList (id: source: ''
        route ${lib.escapeShellArg id} ${lib.escapeShellArg "${source}/SKILL.md"} ${bodyFor id}
      '') sources
    )}
  ''
