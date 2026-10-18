"""公開PIDだけへのSIGINTによるnative検証commandの取消完了の検査

入力 WITHIN に指定したnative検証入口の絶対path
前提 PATH 上のbashとsetsid
出力 取消status130と子孫回収の成立時に終了status0
副作用 一時workspace内で起動したcommandの所有
失敗 ready前の終了と取消完了待機の超過と子孫の未回収
"""

import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

WITHIN = os.environ["WITHIN"]
WAIT_SECONDS = 20.0
POLL_SECONDS = 0.05

# command の期限が短いとSIGINTを無視する実装もtimeoutで終了するため検査待機より長い期限
BUDGET_SECONDS = "300"

# process group だけではsetsid済みの子孫へ届かないため別sessionの停止完了印
COMMAND = """\
setsid bash -c '
  trap "sleep 1; : > stopped; exit 0" TERM
  echo $$ > grandchild.pid
  : > ready
  while :; do sleep 0.05; done
' </dev/null >/dev/null 2>&1 &
wait
"""

with tempfile.TemporaryDirectory() as directory:
    workspace = Path(directory)
    (workspace / "command.sh").write_text(COMMAND, encoding="utf-8")
    # Bashのbackground起動ではSIGINT無視を継承するためforegroundと同じsubprocess起動
    run = subprocess.Popen(
        [WITHIN, BUDGET_SECONDS, "bash", "command.sh"],
        cwd=workspace,
        stdin=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + WAIT_SECONDS
        while not (workspace / "ready").exists():
            if run.poll() is not None:
                raise AssertionError("run-within ended before the command was ready")
            if time.monotonic() >= deadline:
                raise AssertionError("timed out waiting for the command to become ready")
            time.sleep(POLL_SECONDS)
        grandchild = int((workspace / "grandchild.pid").read_text(encoding="utf-8"))

        run.send_signal(signal.SIGINT)
        status = run.wait(timeout=WAIT_SECONDS)
        if status != 128 + signal.SIGINT:
            raise AssertionError(f"SIGINT cancellation returned {status} instead of 130")
        if not (workspace / "stopped").exists():
            raise AssertionError("returned before the descendant finished stopping")
        if Path(f"/proc/{grandchild}").exists():
            raise AssertionError("returned before the descendant was reaped")
        print("public PID SIGINT: exit=130 descendant=reaped")
    finally:
        if run.poll() is None:
            run.terminate()
            run.wait(timeout=WAIT_SECONDS)
