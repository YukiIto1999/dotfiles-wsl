# 隔離した build の builder として、取得した不変な source を package ABI、host が審査した frontmatter、
# source 内に閉じた symlink、host が固定した版の package 検査器で検査する。source の script は実行しない。
set -euo pipefail

reviewed_manifest=@reviewedManifest@
checker=@checker@

fail() {
  printf 'standard package validation: %s\n' "$1" >&2
  exit 1
}

frontmatter() {
  awk 'NR == 1 && $0 != "---" { exit 1 } { print } NR > 1 && $0 == "---" { closed = 1; exit } END { exit !closed }' "$1"
}

source=$1
revision=$2

# 宣言の欠落、文字列、小数を互換とみなさない
jq -es 'length == 1 and (.[0].skillPackageAbi | type == "number" and tojson == "1")' "$source/package.json" >/dev/null \
  || fail 'package.json does not declare the supported integer skillPackageAbi 1'

while IFS= read -r -d '' link; do
  case "$(realpath -m -- "$link")" in
    "$source"/*) ;;
    *) fail "a symlink leaves the source: ${link#"$source"/}" ;;
  esac
done < <(find "$source" -type l -print0)

# 名前、起動 flag、routing の記述は host が審査した版と同じ場合だけ受け入れる
while IFS=$'\t' read -r id reviewed; do
  if ! candidate=$(frontmatter "$source/skills/$id/SKILL.md") \
    || [ "$candidate" != "$(frontmatter "$reviewed/SKILL.md")" ]; then
    fail "$id: SKILL.md frontmatter differs from the host-reviewed source"
  fi
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$reviewed_manifest")

bash "$checker" --standard-root "$source" >&2 || fail 'the host-pinned package checker rejected the source'

mkdir "${out:?}"
printf '%s\n' "$revision" >"$out/revision"
ln -s "$source" "$out/source"
