guard_omp_arguments() {
  case "${1-}" in
    --|--help|-h|--version|-v) return 0 ;;
    gc|-*) ;;
    *) return 0 ;;
  esac

  # launch flag が gc の前にも置けるため先頭引数だけでの判定は不可
  local argument gc=false apply=false
  for argument; do
    case "$argument" in
      gc) gc=true ;;
      --apply|--apply=*) apply=true ;;
    esac
  done
  if "$gc" && "$apply"; then
    printf '%s\n' 'omp: managed sessions do not allow omp gc --apply; use omp gc without --apply to preview.' >&2
    exit 77
  fi
}

guard_omp_arguments "$@"
