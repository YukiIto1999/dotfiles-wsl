: "${FIXTURE_STORE:?}" "${FIXTURE_GCROOTS:?}"

# Nix の GC と同じく、実在する root から辿れる store 実体だけを残す。
# 消えた世代 link を指す間接 root は無効になる
declare -A live=()
for root in "$FIXTURE_GCROOTS"/*; do
  [[ -L $root ]] || continue
  resolved=$(readlink -f -- "$root") || continue
  live[$resolved]=1
done
for entry in "$FIXTURE_STORE"/*; do
  [[ -d $entry ]] || continue
  if [[ -z ${live[$entry]:-} ]]; then
    rm -rf -- "$entry"
  fi
done
