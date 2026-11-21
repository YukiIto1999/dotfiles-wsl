{
  writeShellApplication,
  curl,
  jq,
}:

writeShellApplication {
  name = "context-dev-scrape";
  runtimeInputs = [
    curl
    jq
  ];
  text = ''
    usage() { printf 'Usage: context-dev-scrape <public HTTPS URL>\nRequires CONTEXT_DEV_API_KEY in this process.\n'; }
    if [[ $# == 1 && $1 == --help ]]; then
      usage
      exit 0
    fi
    if [[ $# != 1 ]]; then
      usage >&2
      exit 2
    fi
    public_url='^https://(([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,63})([/?#][^[:space:][:cntrl:]]*)?$'
    if [[ ! $1 =~ $public_url ]]; then
      printf 'context-dev-scrape: expected one public HTTPS URL without credentials or an explicit port\n' >&2
      exit 2
    fi
    case ''${BASH_REMATCH[1],,} in
      *.local|*.localhost|*.internal|*.lan|*.home|*.test|*.invalid)
        printf 'context-dev-scrape: private or reserved host refused\n' >&2
        exit 2
        ;;
    esac
    : "''${CONTEXT_DEV_API_KEY:?context-dev-scrape requires a Context.dev API key}"

    jq -nc --arg url "$1" '{url:$url, formats:{markdown:true}, sharedParams:{mainContentOnly:true}}' |
      curl --disable --silent --show-error --fail --proto '=https' --connect-timeout 5 --max-time 40 --max-filesize 4194304 \
        --variable '%CONTEXT_DEV_API_KEY' --expand-header 'Authorization: Bearer {{CONTEXT_DEV_API_KEY}}' \
        --header 'Content-Type: application/json' --data-binary @- https://api.context.dev/v1/web/scrape |
      jq -e 'if .markdown.success == true and (.markdown.data | type == "string" and length > 0) then
        {url, title:.metadata.title, markdown:.markdown.data}
      else error("Context.dev did not return Markdown") end'
  '';
}
