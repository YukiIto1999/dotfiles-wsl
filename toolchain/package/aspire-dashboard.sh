# shellcheck shell=bash

# 4317/4318 は AI CLI 利用量の collector が使うため、Dashboard は旧来の 18889/18890 で OTLP を受ける
readonly frontend_url=http://127.0.0.1:18888
readonly otlp_grpc_url=http://127.0.0.1:18889
readonly otlp_http_url=http://127.0.0.1:18890

usage() {
  printf '%s\n' \
    'Usage: aspire-dashboard run [--browser-token-stdin]' \
    '       aspire-dashboard status' \
    '       aspire-dashboard otel logs|spans|traces [aspire otel options...]' \
    '       aspire-dashboard exec [--service NAME] -- COMMAND [ARG...]' \
    '       aspire-dashboard stop' \
    '' \
    'run     Start one local Aspire Dashboard in the foreground; Ctrl+C stops it and deletes its data.' \
    "        UI ${frontend_url}, OTLP/gRPC ${otlp_grpc_url}, OTLP/HTTP ${otlp_http_url}." \
    '        For browser login, --browser-token-stdin reads a fresh 64-digit hexadecimal token.' \
    'status  Exit 0 when this run of the dashboard accepts its own browser token,' \
    '        1 when it is not running, 3 while starting.' \
    'otel    Run the official aspire otel reader against the running dashboard.' \
    'exec    Run COMMAND with OTEL_* variables that send its telemetry to the dashboard.' \
    '        By default, telemetry identifies the checkout by its name and a hash of its path.' \
    'stop    Stop the running dashboard and wait until its data is deleted.' \
    '        If an interrupted run left data behind, delete it without starting a dashboard.' \
    '' \
    'Credentials stay in process memory; never pass a browser token in a command argument.'
}

usage_error() {
  usage >&2
  exit 2
}

die() {
  printf 'aspire-dashboard: %s\n' "$1" >&2
  exit "${2:-1}"
}

if [[ $# == 0 ]]; then
  usage_error
fi
case $1 in
  --help | -h | help)
    usage
    exit 0
    ;;
esac

runtime_root=${XDG_RUNTIME_DIR:?aspire-dashboard requires XDG_RUNTIME_DIR}
state=$runtime_root/aspire-dashboard
lock=$runtime_root/aspire-dashboard.lock

# run の後片付けと signal 転送が参照する
run_data=''
run_child=''
run_signalled=0
# locate_run が検証した、資格情報を環境に持つ CLI process
run_pid=''
located_id=''

random_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# 資格情報は file に書かず、起動した CLI process の環境だけに置く。
# 同じ user だけが読める /proc/PID/environ から、値を argv に載せずに取り出す
env_value() {
  local entry
  while IFS= read -r -d '' entry; do
    if [[ $entry == "$2="* ]]; then
      printf '%s' "${entry#*=}"
      return 0
    fi
  done <"/proc/$1/environ"
  return 1
}

# run の wrapper と Dashboard の process group が lock を持つ間だけ稼働中とみなす
lock_held() {
  local fd
  [[ -e $lock ]] || return 1
  exec {fd}<"$lock"
  if flock -n "$fd"; then
    exec {fd}<&-
    return 1
  fi
  exec {fd}<&-
}

# 記録した pid が今回の run の CLI であることを、環境の run ID で確かめる。
# 1 は未起動、2 は起動中または記録の検証前
locate_run() {
  local pid id
  lock_held || return 1
  [[ -f $state/run ]] || return 2
  read -r pid id <"$state/run" || return 2
  [[ $pid =~ ^[0-9]+$ && $id =~ ^[0-9a-f]{32}$ ]] || return 2
  [[ $(env_value "$pid" ASPIRE_DASHBOARD_RUN_ID 2>/dev/null) == "$id" ]] || return 2
  run_pid=$pid
  located_id=$id
}

terminate_run() {
  # 照合後の PID 再利用で無関係な process に届くため通常の kill は不可
  python3 -I -c '
import os
import signal
import sys

pid, run_id = int(sys.argv[1]), sys.argv[2]
try:
    fd = os.pidfd_open(pid)
    with open(f"/proc/{pid}/environ", "rb") as f:
        if ("ASPIRE_DASHBOARD_RUN_ID=" + run_id).encode() not in f.read().split(b"\0"):
            sys.exit(1)
    signal.pidfd_send_signal(fd, signal.SIGTERM)
except OSError:
    sys.exit(1)
' "$1" "$2"
}

# 今回の browser token を受理した応答だけを、自分の Dashboard の受付とみなす。応答の API key は捨てる
dashboard_accepts() {
  local token code
  token=$(env_value "$run_pid" DASHBOARD__FRONTEND__BROWSERTOKEN) || return 1
  code=$(printf '{"token":"%s"}' "$token" |
    curl --silent --output /dev/null --write-out '%{http_code}' --max-time 2 \
      --header 'Content-Type: application/json' --data-binary @- \
      "$frontend_url/api/telemetry/validateToken") || return 1
  [[ $code == 200 ]]
}

require_ready() {
  local status=0
  locate_run || status=$?
  case $status in
    0) ;;
    1) die 'not running; start it with: aspire-dashboard run' ;;
    *) die 'still starting; retry after aspire-dashboard status exits 0' 3 ;;
  esac
  dashboard_accepts || die 'still starting; retry after aspire-dashboard status exits 0' 3
}

stop_group() {
  local pgid=$1 attempt
  kill -0 -- "-$pgid" 2>/dev/null || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  for ((attempt = 0; attempt < 100; attempt++)); do
    kill -0 -- "-$pgid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

run_cleanup() {
  if [[ -n $run_child ]]; then
    stop_group "$run_child"
  fi
  rm -rf -- "$state"
  if [[ -n $run_data ]]; then
    rm -rf -- "$run_data"
  fi
}

# setsid が session を作る前は process group が無いため、子の pid へ直接送る
signal_run_child() {
  kill -TERM -- "-$run_child" 2>/dev/null || kill -TERM "$run_child" 2>/dev/null || true
}

run_signal() {
  run_signalled=1
  if [[ -n $run_child ]]; then
    signal_run_child
  fi
}

# wrapper が強制終了した run の残りを、lock を持つ側だけが消す。記録した自分の一時 directory 以外は消さない
remove_previous_run() {
  local previous
  if [[ -f $state/data-dir ]]; then
    previous=$(<"$state/data-dir")
    if [[ ${previous##*/} == aspire-dashboard.???????? && -d $previous && ! -L $previous && -O $previous ]]; then
      rm -rf -- "$previous"
    fi
  fi
  rm -rf -- "$state"
}

cmd_run() {
  local status=0 run_id browser_token
  if [[ $# == 0 ]]; then
    browser_token=$(random_hex 32)
  elif [[ $# == 1 && $1 == --browser-token-stdin ]]; then
    if [[ -t 0 ]]; then
      IFS= read -r -s -p 'Aspire Dashboard browser token: ' browser_token || die 'missing browser token' 2
      printf '\n' >&2
    else
      IFS= read -r browser_token || die 'missing browser token' 2
    fi
    [[ $browser_token =~ ^[0-9a-fA-F]{64}$ ]] || die 'expected a fresh 64-digit hexadecimal browser token' 2
  else
    usage_error
  fi
  umask 077
  exec 9>>"$lock"
  flock -n 9 || die 'already running; use aspire-dashboard status, otel, exec or stop'
  remove_previous_run
  trap run_cleanup EXIT
  trap run_signal INT TERM HUP
  mkdir -m 700 -- "$state"
  run_data=$(mktemp -d "${TMPDIR:-/tmp}/aspire-dashboard.XXXXXXXX")
  printf '%s\n' "$run_data" >"$state/data-dir"
  run_id=$(random_hex 16)

  printf '%s\n' 'aspire-dashboard: read with "aspire-dashboard otel", send with "aspire-dashboard exec -- COMMAND"' >&2

  # 端末の Ctrl+C は wrapper だけが受け、Dashboard を含む process group 全体へ TERM を送る。
  # wrapper が強制終了しても、pdeathsig で CLI が止まり、CLI の監視で Dashboard も止まる。
  # project の aspire.config.json を読まないよう、CWD は私有 directory に置く。
  # None mode の一時 SQLite と CLI の log は TMPDIR の下に作られ、異常終了時も次の run か stop が消す。
  # browser token と OTLP key は環境変数だけで渡す。telemetry API key は CLI が生成し、otel は token から交換する。
  # ASP.NET Core の request log は login URL の query を記録するため Warning 以上に絞る
  cd -- "$state" || exit 1
  ASPIRE_DASHBOARD_RUN_ID=$run_id \
    DASHBOARD__FRONTEND__AUTHMODE=BrowserToken \
    DASHBOARD__FRONTEND__BROWSERTOKEN=$browser_token \
    DASHBOARD__OTLP__AUTHMODE=ApiKey \
    DASHBOARD__OTLP__PRIMARYAPIKEY=$(random_hex 32) \
    ASPIRE_DASHBOARD_SUPPRESS_BROWSER_TOKEN_IN_OUTPUT=true \
    TMPDIR=$run_data \
    setsid setpriv --pdeathsig TERM aspire dashboard run \
    --nologo \
    --non-interactive \
    --log-file "$run_data/dashboard.log" \
    --frontend-url "$frontend_url" \
    --otlp-grpc-url "$otlp_grpc_url" \
    --otlp-http-url "$otlp_http_url" \
    --persistence None \
    --Logging:LogLevel:Microsoft.AspNetCore=Warning \
    --Dashboard:TelemetryLimits:MaxLogCount=10000 \
    --Dashboard:TelemetryLimits:MaxTraceCount=10000 \
    --Dashboard:TelemetryLimits:MaxMetricsCount=10000 \
    --Dashboard:TelemetryLimits:MaxAttributeLength=8192 \
    --Dashboard:TelemetryLimits:MaxSpanEventCount=128 \
    </dev/null &
  run_child=$!
  printf '%s %s\n' "$run_child" "$run_id" >"$state/run.new"
  mv -- "$state/run.new" "$state/run"
  if ((run_signalled)); then
    signal_run_child
  fi

  while :; do
    if wait "$run_child"; then
      status=0
    else
      status=$?
    fi
    kill -0 "$run_child" 2>/dev/null || break
  done
  if ((run_signalled)) || [[ -e $state/stop-$run_id ]]; then
    exit 0
  fi
  exit "$status"
}

cmd_status() {
  local status=0
  [[ $# == 0 ]] || usage_error
  locate_run || status=$?
  if ((status == 1)); then
    printf 'aspire-dashboard: not running\n'
    exit 1
  fi
  if ((status != 0)) || ! dashboard_accepts; then
    printf 'aspire-dashboard: starting\n'
    exit 3
  fi
  printf 'aspire-dashboard: ready %s (OTLP/gRPC %s, OTLP/HTTP %s)\n' "$frontend_url" "$otlp_grpc_url" "$otlp_http_url"
}

cmd_otel() {
  local signal token
  [[ $# -ge 1 ]] || usage_error
  signal=$1
  shift
  case $signal in
    logs | spans | traces) ;;
    *) usage_error ;;
  esac
  require_ready
  token=$(env_value "$run_pid" DASHBOARD__FRONTEND__BROWSERTOKEN)

  # 公式 CLI は response file を複数回開くため一度しか読めない pipe は不可
  cd -- "$state" || exit 1
  printf '%s\n' --dashboard-url "$frontend_url/login?t=$token" |
    python3 -I -c '
import os
import sys

fd = os.memfd_create("aspire-response")
with os.fdopen(os.dup(fd), "wb") as response:
    response.write(sys.stdin.buffer.read())
os.set_inheritable(fd, True)
os.execvp("aspire", ["aspire", "otel", sys.argv[1], "--nologo", "--non-interactive",
                    f"@/proc/self/fd/{fd}", *sys.argv[2:]])
' "$signal" "$@"
}

has_resource_attribute() {
  local entry key
  local -a entries
  IFS=, read -r -a entries <<<"$1"
  for entry in "${entries[@]}"; do
    [[ $entry == *=* ]] || continue
    key=${entry%%=*}
    key=${key#"${key%%[![:space:]]*}"}
    key=${key%"${key##*[![:space:]]}"}
    [[ $key != "$2" ]] || return 0
  done
  return 1
}

cmd_exec() {
  local service='' root name digest checkout attributes key
  while [[ $# -gt 0 ]]; do
    case $1 in
      --service)
        [[ $# -ge 2 && -n $2 ]] || usage_error
        service=$2
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *) usage_error ;;
    esac
  done
  [[ $# -ge 1 ]] || usage_error
  require_ready
  key=$(env_value "$run_pid" DASHBOARD__OTLP__PRIMARYAPIKEY) || die 'could not read the OTLP key of this run'

  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$(pwd -P)
  name=${root##*/}
  name=${name//[^A-Za-z0-9._-]/-}
  digest=$(printf '%s' "$root" | sha256sum)
  checkout=${name:-root}-${digest:0:12}
  attributes=${OTEL_RESOURCE_ATTRIBUTES-}
  if ! has_resource_attribute "$attributes" service.namespace; then
    attributes+=${attributes:+,}service.namespace=$checkout
  fi
  if ! has_resource_attribute "$attributes" service.instance.id; then
    attributes+=,service.instance.id=$(random_hex 8)
  fi

  # 信号別の設定が残ると別の collector へ送るため、送信先はこの Dashboard だけにする
  unset OTEL_EXPORTER_OTLP_TRACES_ENDPOINT OTEL_EXPORTER_OTLP_METRICS_ENDPOINT OTEL_EXPORTER_OTLP_LOGS_ENDPOINT
  unset OTEL_EXPORTER_OTLP_TRACES_HEADERS OTEL_EXPORTER_OTLP_METRICS_HEADERS OTEL_EXPORTER_OTLP_LOGS_HEADERS
  unset OTEL_EXPORTER_OTLP_TRACES_PROTOCOL OTEL_EXPORTER_OTLP_METRICS_PROTOCOL OTEL_EXPORTER_OTLP_LOGS_PROTOCOL
  export OTEL_EXPORTER_OTLP_HEADERS="x-otlp-api-key=$key"
  export OTEL_EXPORTER_OTLP_ENDPOINT=$otlp_http_url
  export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
  export OTEL_RESOURCE_ATTRIBUTES=$attributes
  if [[ -n $service ]]; then
    export OTEL_SERVICE_NAME=$service
  elif [[ -z ${OTEL_SERVICE_NAME-} ]] && ! has_resource_attribute "$attributes" service.name; then
    export OTEL_SERVICE_NAME=$checkout
  fi
  exec -- "$@"
}

cmd_stop() {
  local status=1 fd attempt stopping
  [[ $# == 0 ]] || usage_error
  umask 077
  exec {fd}>>"$lock"
  # 稼働中に状態を消すと別の run を起動できるため回収には lock の取得が必須
  for ((attempt = 0; attempt < 100; attempt++)); do
    if flock -n "$fd"; then
      if [[ -e $state ]]; then
        remove_previous_run
        printf 'aspire-dashboard: not running; removed data left by an interrupted run\n'
      else
        printf 'aspire-dashboard: not running\n'
      fi
      return 0
    fi
    status=0
    locate_run || status=$?
    ((status != 0)) || break
    sleep 0.1
  done
  ((status == 0)) || die 'could not verify the running dashboard process'
  stopping=$located_id
  { : >"$state/stop-$stopping"; } 2>/dev/null || true
  terminate_run "$run_pid" "$stopping" || true
  for ((attempt = 0; attempt < 300; attempt++)); do
    if flock -n "$fd"; then
      remove_previous_run
      printf 'aspire-dashboard: stopped\n'
      return 0
    fi
    # 再起動した run まで待つと先の stop が失敗したと誤報するため ID で分離
    if locate_run && [[ $located_id != "$stopping" ]]; then
      printf 'aspire-dashboard: stopped\n'
      return 0
    fi
    sleep 0.1
  done
  die 'dashboard did not stop within 30 seconds'
}

command=$1
shift
case $command in
  run) cmd_run "$@" ;;
  status) cmd_status "$@" ;;
  otel) cmd_otel "$@" ;;
  exec) cmd_exec "$@" ;;
  stop) cmd_stop "$@" ;;
  *) usage_error ;;
esac
