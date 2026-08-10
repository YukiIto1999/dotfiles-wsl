set -euo pipefail

has_link_option=false
for argument in "$@"; do
  case "$argument" in
    --)
      break
      ;;
    --no-out-link|--out-link|--out-link=*|-o|-o?*)
      has_link_option=true
      break
      ;;
  esac
done

if [ "$has_link_option" = true ]; then
  exec @nixBuildCommand@ "$@"
fi

exec @nixBuildCommand@ --no-out-link "$@"
