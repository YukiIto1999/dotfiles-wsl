output_dir=
while (( $# > 0 )); do
  case $1 in
    --output-dir)
      output_dir=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

test -n "$output_dir"
printf '%s\n' "$output_dir" >> "$PLAYWRIGHT_MCP_TEST_LOG"
printf 'session-scoped\n' > "$output_dir/result.txt"
printf '%s\n' "$$" > "$output_dir/child.pid"
if [[ -n ${PLAYWRIGHT_MCP_TEST_CHILD_LOG:-} ]]; then
  printf '%s\n' "$$" > "$PLAYWRIGHT_MCP_TEST_CHILD_LOG"
fi

case ${PLAYWRIGHT_MCP_TEST_MODE:-pass} in
  wait)
    while [[ ! -e $PLAYWRIGHT_MCP_TEST_RELEASE ]]; do
      sleep 0.05
    done
    ;;
  fail)
    exit 23
    ;;
  stdio)
    IFS= read -r request
    printf '%s\n' "$request" > "$PLAYWRIGHT_MCP_TEST_STDIN_LOG"
    ;;
  interrupt)
    kill -INT "$PPID"
    while true; do
      sleep 0.05
    done
    ;;
esac
