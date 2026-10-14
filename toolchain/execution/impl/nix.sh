set -euo pipefail

arguments=("$@")
argument_count=${#arguments[@]}
subcommand_index=0

while [ "$subcommand_index" -lt "$argument_count" ]; do
  argument=${arguments[$subcommand_index]}
  case "$argument" in
    --option)
      test "$((subcommand_index + 2))" -lt "$argument_count" || exec @nixCommand@ "$@"
      subcommand_index=$((subcommand_index + 3))
      ;;
    --log-format|--extra-experimental-features|--extra-deprecated-features|--experimental-features|--store)
      test "$((subcommand_index + 1))" -lt "$argument_count" || exec @nixCommand@ "$@"
      subcommand_index=$((subcommand_index + 2))
      ;;
    --log-format=*|--extra-experimental-features=*|--extra-deprecated-features=*|--experimental-features=*|--store=*)
      subcommand_index=$((subcommand_index + 1))
      ;;
    --debug|--offline|--print-build-logs|-L|--quiet|--refresh|--verbose|-v)
      subcommand_index=$((subcommand_index + 1))
      ;;
    -*|'')
      exec @nixCommand@ "$@"
      ;;
    *)
      break
      ;;
  esac
done

if [ "$subcommand_index" -ge "$argument_count" ] \
  || [ "${arguments[$subcommand_index]}" != build ]; then
  exec @nixCommand@ "$@"
fi

has_link_option=false
for argument in "${arguments[@]:subcommand_index+1}"; do
  case "$argument" in
    --)
      break
      ;;
    --no-link|--out-link|--out-link=*|-o|-o?*)
      has_link_option=true
      break
      ;;
  esac
done

if [ "$has_link_option" = true ]; then
  exec @nixCommand@ "$@"
fi

before_build_arguments=("${arguments[@]:0:subcommand_index+1}")
build_arguments=("${arguments[@]:subcommand_index+1}")
exec @nixCommand@ "${before_build_arguments[@]}" --no-link "${build_arguments[@]}"
