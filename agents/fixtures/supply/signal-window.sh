#!/usr/bin/env bash
# 供給の指定した関数frameの開始境界での取消signal注入
# 入力 FIXTURE_SIGNAL_POINT: 注入を1回に限るmarker fileのpath
# 入力 FIXTURE_SIGNAL_FUNCTION: 注入先frameを持つ供給の関数名
# 入力 FIXTURE_SIGNAL_SECOND_ARGUMENT: 注入先frameの第2位置引数
# 入力 FIXTURE_SIGNAL_COMMAND: DEBUG trapで照合するBash command
# 任意入力 FIXTURE_SIGNAL_AWAIT: 注入前に存在を待つfileのpath
# 入力 cancelled: 注入先frameのshellが記録する取消状態
# 出力: markerの.firedへの移動と.childへの直近の非同期子pid記録
# 副作用: 供給entrypointへのTERMと注入先frameでの取消記録待機
# 前提: functraceを有効にしてBASH_ENVとして読込
: "${FIXTURE_SIGNAL_POINT:?}"
: "${FIXTURE_SIGNAL_FUNCTION:?}"
: "${FIXTURE_SIGNAL_SECOND_ARGUMENT:?}"
: "${FIXTURE_SIGNAL_COMMAND:?}"
declare cancelled

# 時間待ち後の外部signalでは取消記録と子登録の前後を固定できないため試験側からのkillは不可
trap '
if [[ ${FUNCNAME[0]-} == "$FIXTURE_SIGNAL_FUNCTION" && ${2-} == "$FIXTURE_SIGNAL_SECOND_ARGUMENT" \
  && $BASH_COMMAND == "$FIXTURE_SIGNAL_COMMAND" && -f $FIXTURE_SIGNAL_POINT ]]; then
  printf "%s\n" "${!-}" >"$FIXTURE_SIGNAL_POINT.child"
  mv -- "$FIXTURE_SIGNAL_POINT" "$FIXTURE_SIGNAL_POINT.fired"
  while [[ -n ${FIXTURE_SIGNAL_AWAIT-} && ! -e ${FIXTURE_SIGNAL_AWAIT-} ]]; do
    sleep 0.01
  done
  kill -TERM "$$"
  while [[ ${cancelled:-0} == 0 ]]; do
    sleep 0.01
  done
fi
' DEBUG
