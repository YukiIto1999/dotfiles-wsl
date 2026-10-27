# 入力 FIXTURE_RECEIPT_FAULT: unwritable は作成直後の mode 000 への変更
path=$(mktemp "$@")
if [[ ${FIXTURE_RECEIPT_FAULT:-} == unwritable && $path == */.receipt.* ]]; then
  chmod 000 -- "$path"
fi
printf '%s\n' "$path"
