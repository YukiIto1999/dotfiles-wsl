# 入力 FIXTURE_RECEIPT_FAULT: reject は公開の失敗、kill は公開の直前に呼出し元の worker への SIGKILL
for argument in "$@"; do
  if [[ $argument == */.receipt.* ]]; then
    case ${FIXTURE_RECEIPT_FAULT:-} in
      reject)
        echo "mv: fixture failure" >&2
        exit 1
        ;;
      kill)
        kill -KILL "$PPID"
        exit 0
        ;;
      *) ;;
    esac
  fi
done
exec mv "$@"
