import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from collections.abc import Callable
from pathlib import Path

RUNNER = Path(sys.argv.pop(1)).resolve()
SUPERVISE = Path(sys.argv.pop(1)).resolve()

LINGER = """\
import signal, sys, time
def late_exit(*_):
    time.sleep(3)
    sys.exit(0)
signal.signal(signal.SIGTERM, late_exit)
open(sys.argv[1], "w").close()
time.sleep(600)
"""
STUBBORN = """\
import signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(sys.argv[1], "w").close()
time.sleep(600)
"""

RECORDER = """\
import os, sys
with open(sys.argv[1], "w", encoding="utf-8") as record:
    record.write(os.environ.get("DOTFILES_JOB_DEADLINE", "") + "\\n" + str(os.getpid()))
sys.exit(int(sys.argv[2]))
"""
WAITER = """\
import os, sys, time
open(sys.argv[1], "w").close()
while not os.path.exists(sys.argv[2]):
    time.sleep(0.05)
"""
NESTING = """\
import os, subprocess, sys, time
open(sys.argv[1], "w", encoding="utf-8").write(os.environ["DOTFILES_JOB_DEADLINE"])
child = subprocess.Popen([sys.executable, "-c", sys.argv[4], sys.argv[3]])
while not os.path.exists(sys.argv[3]):
    time.sleep(0.02)
open(sys.argv[2], "w", encoding="utf-8").write(str(child.pid))
time.sleep(600)
"""
DEATH = """\
import os, signal, subprocess, sys, time
child = subprocess.Popen([sys.executable, "-c", sys.argv[3], sys.argv[2]])
while not os.path.exists(sys.argv[2]):
    time.sleep(0.02)
open(sys.argv[1], "w", encoding="utf-8").write(str(child.pid))
os.kill(os.getpid(), signal.SIGKILL)
"""
INSPECTOR = """\
import os, sys
roots = os.path.join(os.environ["XDG_RUNTIME_DIR"], "dotfiles-agent-job", "journal.roots")
with open(sys.argv[1], "w", encoding="utf-8") as record:
    record.write("\\n".join(sorted(os.listdir(roots))))
"""
PROTECT = """\
import os, sys
if os.environ.get("FAKE_PROTECT_FAIL"):
    sys.exit("cannot take a root")
resolved = sys.argv[1] == "--resolved"
roots, *paths = sys.argv[1 + resolved:]
for index, path in enumerate(paths):
    os.symlink(os.path.realpath(path), os.path.join(roots, f"{index}-held"))
if resolved:
    print("\\n".join(os.path.realpath(path) for path in paths))
"""
STALLED_PROTECT = """\
import os, subprocess, sys, time
roots, first = [argument for argument in sys.argv[1:] if argument != "--resolved"][:2]
os.symlink(os.path.realpath(first), os.path.join(roots, "0-held"))
subprocess.Popen([os.environ["FAKE_CLEANUP"], roots, os.environ["FAKE_CLEANUP_RECORD"], os.environ["FAKE_CLEANUP_PID"]])
time.sleep(30)
"""
CLEANUP = """\
import fcntl, os, signal, sys, time
roots, record, pid_file = sys.argv[1:]
lock = os.path.join(os.environ["XDG_RUNTIME_DIR"], "dotfiles-agent-job", "journal.lock")

def end(*_):
    time.sleep(1)
    with open(lock, "rb") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lock_state = "free"
        except BlockingIOError:
            lock_state = "held"
    root_state = "present" if os.path.islink(os.path.join(roots, "0-held")) else "gone"
    with open(record, "w", encoding="utf-8") as stream:
        stream.write(f"{root_state} {lock_state}")
    sys.exit(0)

signal.signal(signal.SIGTERM, end)
with open(pid_file + ".tmp", "w", encoding="utf-8") as stream:
    stream.write(str(os.getpid()))
os.replace(pid_file + ".tmp", pid_file)
time.sleep(30)
"""
CALLER = """\
import json, os, subprocess, sys, time
arguments = sys.argv[1:]
program = arguments[arguments.index("--omp") + 1]
ready, release, record = arguments[-3:]
roots = os.path.join(os.environ["XDG_RUNTIME_DIR"], "dotfiles-agent-job", "journal.roots")
held = [os.readlink(os.path.join(roots, name)) for name in sorted(os.listdir(roots))]
open(ready, "w").close()
while not os.path.exists(release):
    time.sleep(0.02)
calls = [subprocess.run([program], capture_output=True, text=True).stdout.strip() for _ in range(3)]
with open(record, "w", encoding="utf-8") as stream:
    json.dump({"arguments": arguments, "held": held, "calls": calls}, stream)
"""


def alive(pid: int) -> bool:
    try:
        with open(f"/proc/{pid}/stat", "rb") as handle:
            return handle.read().rpartition(b") ")[2].split()[0] != b"Z"
    except OSError:
        return False


def wait_for(path: Path, timeout: float = 15) -> None:
    end = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() > end:
            raise AssertionError(f"{path} did not appear")
        time.sleep(0.02)


class JobRunner(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="agent-job-test-")
        self.addCleanup(workspace.cleanup)
        self.workspace = Path(workspace.name)
        self.runtime = self.workspace / "run"
        self.runtime.mkdir(mode=0o700)
        self.protect = self.script("protect", PROTECT)
        self.started: list[subprocess.Popen] = []
        self.addCleanup(self.stop_leftovers)

    def stop_leftovers(self):
        for process in self.started:
            if process.poll() is None:
                process.kill()
                process.wait()
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()

    def script(self, name: str, body: str) -> Path:
        path = self.workspace / name
        path.write_text(f"#!{sys.executable}\n{body}", encoding="utf-8")
        path.chmod(0o755)
        return path

    def start(
        self,
        name: str,
        worker: list,
        limit: float = 60,
        drain: float = 5,
        hold: tuple = (),
        executables: dict | None = None,
        environment: dict | None = None,
        protect: Path | None = None,
    ) -> subprocess.Popen:
        """runner の子 process の起動

        name: job 名
        worker: -- の後へ渡す program と引数の列
        limit: 絶対の実行期限の秒数
        drain: TERM から KILL までの猶予秒数
        hold: 保護する実行依存の path の列
        executables: 宣言する option 名から既定の path への対応
        environment: テスト用 runtime directory を指す XDG_RUNTIME_DIR を含む環境へ上書きする環境変数
        protect: 保護 command の path で None は self.protect の fake
        戻り値: 標準入力を空にし標準出力と標準エラーを pipe にした runner の process
        副作用: テスト終了時の後始末対象への process の登録
        """
        command = [
            sys.executable, str(RUNNER),
            "--name", name,
            "--limit-seconds", str(limit),
            "--drain-seconds", str(drain),
            "--supervise", str(SUPERVISE),
            "--protect", str(protect or self.protect),
            *[argument for path in hold for argument in ("--hold", str(path))],
            *[argument for name, path in (executables or {}).items() for argument in ("--executable", f"{name}={path}")],
            "--", *[str(part) for part in worker],
        ]
        process = subprocess.Popen(
            command,
            env={**os.environ, "XDG_RUNTIME_DIR": str(self.runtime), **(environment or {})},
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.started.append(process)
        return process

    def finish(self, process: subprocess.Popen, timeout: float = 30) -> tuple[int, str]:
        _, stderr = process.communicate(timeout=timeout)
        return process.returncode, stderr

    def run_job(self, name: str, worker: list, **options) -> tuple[int, str]:
        return self.finish(self.start(name, worker, **options))

    def recorder(self, name: str) -> Path:
        return self.script(name, RECORDER)

    def runs_again(self, name: str, marker: Path) -> None:
        recorder = self.recorder(f"again-{marker.name}")
        end = time.monotonic() + 30
        while True:
            status, _ = self.run_job(name, [recorder, marker, 0])
            if status == 0:
                return
            self.assertEqual(status, 75)
            self.assertLess(time.monotonic(), end)
            time.sleep(0.2)

    def program(self, root: Path, version: str) -> Path:
        """version を標準出力へ出す実行 file の作成

        root: version ごとの directory を作る場所
        version: 実行 file が出力する識別子で directory 名にも使用
        戻り値: root/version/omp の path
        前提: root/version が未作成
        失敗: root/version が作成済みのとき FileExistsError
        """
        path = root / version / "omp"
        path.parent.mkdir(parents=True)
        path.write_text(f"#!{sys.executable}\nprint({version!r})\n", encoding="utf-8")
        path.chmod(0o755)
        return path

    def start_with_stalled_protection(self, limit: float) -> tuple[subprocess.Popen, Path, Path, Path]:
        """終了要求まで戻らない保護 command の下での job の起動

        limit: 絶対の実行期限の秒数
        戻り値: runner の process と record と pid_file と marker の組
        record: 保護の子孫が終了する直前の root と lock の状態を書く file
        pid_file: 保護の子孫の pid を書く file
        marker: worker が起動した場合に作る file
        前提: 終了要求を送る前の pid_file の出現の待機
        不変条件: 保護が完了しないため worker は起動しない
        """
        held = self.workspace / "dependency"
        held.write_text("dependency")
        record, pid_file, marker = (self.workspace / name for name in ("cleanup-record", "cleanup-pid", "marker"))
        environment = {
            "FAKE_CLEANUP": str(self.script("cleanup", CLEANUP)),
            "FAKE_CLEANUP_RECORD": str(record),
            "FAKE_CLEANUP_PID": str(pid_file),
        }
        job = self.start(
            "journal",
            [self.recorder("recorder"), marker, 0],
            limit=limit,
            hold=(held,),
            environment=environment,
            protect=self.script("stalled-protect", STALLED_PROTECT),
        )
        return job, record, pid_file, marker

    def assert_protection_ended_while_held(self, record: Path, pid_file: Path) -> None:
        """保護の子孫の終了順序の検証

        record: 保護の子孫が終了する直前の root と lock の状態を書いた file
        pid_file: 保護の子孫の pid を書いた file
        前提: runner の終了後の呼び出し
        検証: 子孫の終了
        検証: 子孫の終了の直前に root が残り lock が保持
        検証: roots directory の解放
        失敗: 検証に反する状態は AssertionError
        """
        descendant = int(pid_file.read_text(encoding="utf-8"))
        self.assertFalse(alive(descendant), "a descendant of the protection outlived the job")
        self.assertTrue(record.exists(), "the descendant of the protection was never asked to end")
        self.assertEqual(record.read_text(encoding="utf-8"), "present held")
        self.assertFalse((self.runtime / "dotfiles-agent-job" / "journal.roots").exists())

    def run_across_profile_moves(self, label: str, supplied: Callable[[Path, Path], list]) -> tuple[dict, dict[str, Path]]:
        """profile の差し替えを跨ぐ worker の実行 file の観測

        label: 作業 directory と worker の script の名前で test 内で一意
        supplied: declared と requested の symlink から worker の追加引数を返す関数
        戻り値: worker の記録と P と Q と R から解決済みの program の path への対応の組
        worker の記録: 受けた引数と起動時の roots の指す先と差し替え後の三回の呼び出し結果
        起動時の対応: declared は P の program を requested は R の program を指す symlink
        差し替え: worker の準備完了後の両 symlink の Q の program への置換
        失敗: worker の準備完了が待機内に現れないとき AssertionError
        失敗: job の終了 status が 0 でないとき AssertionError
        """
        root = self.workspace / label
        root.mkdir()
        programs = {version: self.program(root, version) for version in "PQR"}
        declared, requested = root / "declared", root / "requested"
        declared.symlink_to(programs["P"])
        requested.symlink_to(programs["R"])
        ready, release, record = (root / name for name in ("ready", "release", "record"))
        worker = [self.script(f"caller-{label}", CALLER), *supplied(declared, requested), ready, release, record]
        job = self.start("journal", worker, executables={"omp": declared})
        wait_for(ready)

        for profile in (declared, requested):
            moved = profile.with_name(f"{profile.name}.next")
            moved.symlink_to(programs["Q"])
            os.replace(moved, profile)
        release.write_text("go")

        self.assertEqual(self.finish(job)[0], 0)
        return json.loads(record.read_text(encoding="utf-8")), {version: path.resolve() for version, path in programs.items()}

    def test_the_worker_status_is_the_job_status_and_each_run_releases_the_lock(self):
        recorder = self.recorder("recorder")
        for code in (0, 3, 0):
            marker = self.workspace / f"marker-{code}"
            status, _ = self.run_job("journal", [recorder, marker, code])
            self.assertEqual(status, code)
            self.assertTrue(marker.exists())

    def test_a_second_request_for_the_same_job_fails_while_an_independent_job_keeps_running(self):
        waiter = self.script("waiter", WAITER)
        recorder = self.recorder("recorder")
        started, release = self.workspace / "started", self.workspace / "release"
        first = self.start("journal", [waiter, started, release])
        wait_for(started)

        status, message = self.run_job("journal", [recorder, self.workspace / "second", 0])
        self.assertEqual(status, 75)
        self.assertIn("another run holds this job", message)
        self.assertFalse((self.workspace / "second").exists())

        status, _ = self.run_job("harvest", [recorder, self.workspace / "independent", 0])
        self.assertEqual(status, 0)
        self.assertTrue((self.workspace / "independent").exists())
        self.assertIsNone(first.poll())

        release.write_text("go")
        self.assertEqual(self.finish(first)[0], 0)

    def test_the_absolute_deadline_reaches_the_worker_and_every_descendant_is_gone_on_return(self):
        nesting = self.script("nesting", NESTING)
        record, pids, ready = self.workspace / "record", self.workspace / "pids", self.workspace / "ready"
        began = time.time()

        status, message = self.run_job("journal", [nesting, record, pids, ready, STUBBORN], limit=2, drain=1)

        self.assertEqual(status, 124)
        self.assertIn("execution limit", message)
        self.assertAlmostEqual(float(record.read_text(encoding="utf-8")), began + 2, delta=2)
        self.assertFalse(alive(int(pids.read_text(encoding="utf-8"))))
        self.runs_again("journal", self.workspace / "after")

    def test_a_cancelled_job_drains_its_children_before_returning_and_is_not_a_success(self):
        nesting = self.script("nesting", NESTING)
        record, pids, ready = self.workspace / "record", self.workspace / "pids", self.workspace / "ready"
        runner = self.start("journal", [nesting, record, pids, ready, STUBBORN], drain=1)
        wait_for(pids)
        child = int(pids.read_text(encoding="utf-8"))
        self.assertTrue(alive(child))

        runner.send_signal(signal.SIGTERM)
        status, message = self.finish(runner)

        self.assertEqual(status, 128 + signal.SIGTERM)
        self.assertIn("cancelled", message)
        self.assertFalse(alive(child))
        self.runs_again("journal", self.workspace / "after")

    def test_an_interrupt_cancels_the_job_although_the_supervisor_ignores_it(self):
        nesting = self.script("nesting", NESTING)
        record, pids, ready = self.workspace / "record", self.workspace / "pids", self.workspace / "ready"
        runner = self.start("journal", [nesting, record, pids, ready, STUBBORN], drain=1)
        wait_for(pids)
        child = int(pids.read_text(encoding="utf-8"))

        runner.send_signal(signal.SIGINT)
        status, _ = self.finish(runner)

        self.assertEqual(status, 128 + signal.SIGINT)
        self.assertFalse(alive(child))

    def test_a_worker_that_dies_alone_cannot_overlap_a_second_writer_with_its_orphans(self):
        death = self.script("death", DEATH)
        pid_file, ready = self.workspace / "orphan", self.workspace / "ready"
        held = self.workspace / "dependency"
        held.write_text("dependency")
        roots = self.runtime / "dotfiles-agent-job" / "journal.roots"

        first = self.start("journal", [death, pid_file, ready, LINGER], drain=10, hold=(held,))
        wait_for(pid_file)
        orphan = int(pid_file.read_text(encoding="utf-8"))
        time.sleep(0.5)
        self.assertTrue(alive(orphan))
        self.assertTrue(roots.is_dir())
        second_status, _ = self.run_job("journal", [self.recorder("second-worker"), self.workspace / "second", 0])
        self.assertEqual(second_status, 75)
        self.assertFalse((self.workspace / "second").exists())

        status, _ = self.finish(first)

        self.assertEqual(status, 128 + signal.SIGKILL)
        self.assertFalse(alive(orphan))
        self.assertFalse(roots.exists())
        self.runs_again("journal", self.workspace / "third")

    def test_the_death_of_the_runner_keeps_the_lock_until_every_descendant_has_ended(self):
        nesting = self.script("nesting", NESTING)
        record, pids, ready = self.workspace / "record", self.workspace / "pids", self.workspace / "ready"
        first = self.start("journal", [nesting, record, pids, ready, LINGER], drain=10)
        wait_for(pids)
        child = int(pids.read_text(encoding="utf-8"))

        first.kill()
        first.wait()
        time.sleep(0.5)

        self.assertTrue(alive(child))
        status, _ = self.run_job("journal", [self.recorder("second-worker"), self.workspace / "second", 0])
        self.assertEqual(status, 75)
        self.assertFalse((self.workspace / "second").exists())

        self.runs_again("journal", self.workspace / "third")
        self.assertFalse(alive(child))

    def test_a_worker_that_cannot_start_is_refused_without_keeping_the_lock_or_roots(self):
        held = self.workspace / "dependency"
        held.write_text("dependency")

        status, message = self.run_job("journal", [self.workspace / "missing-worker"], hold=(held,))

        self.assertEqual(status, 127)
        self.assertIn("cannot execute", message)
        self.assertFalse((self.runtime / "dotfiles-agent-job" / "journal.roots").exists())
        self.runs_again("journal", self.workspace / "after")

    def test_execution_dependencies_are_rooted_before_the_worker_starts_and_released_after_it_ends(self):
        inspector = self.script("inspector", INSPECTOR)
        first, second = self.workspace / "first", self.workspace / "second"
        first.write_text("first")
        second.write_text("second")
        record = self.workspace / "record"

        status, _ = self.run_job("journal", [inspector, record], hold=(first, second))

        self.assertEqual(status, 0)
        self.assertEqual(record.read_text(encoding="utf-8").splitlines(), ["0-held", "1-held"])
        self.assertFalse((self.runtime / "dotfiles-agent-job" / "journal.roots").exists())

    def test_a_job_whose_dependencies_cannot_be_protected_never_starts_its_worker(self):
        held = self.workspace / "dependency"
        held.write_text("dependency")
        marker = self.workspace / "marker"

        status, message = self.run_job(
            "journal", [self.recorder("recorder"), marker, 0], hold=(held,), environment={"FAKE_PROTECT_FAIL": "1"}
        )

        self.assertEqual(status, 70)
        self.assertIn("cannot protect the execution dependencies", message)
        self.assertFalse(marker.exists())
        self.assertEqual(self.run_job("journal", [self.recorder("recorder"), marker, 0], hold=(held,))[0], 0)

    def test_a_job_without_a_runtime_directory_is_refused_instead_of_running_unlocked(self):
        marker = self.workspace / "marker"
        environment = {key: value for key, value in os.environ.items() if key != "XDG_RUNTIME_DIR"}
        process = subprocess.run(
            [
                sys.executable, str(RUNNER), "--name", "journal", "--limit-seconds", "5", "--drain-seconds", "1",
                "--supervise", str(SUPERVISE), "--protect", str(self.protect),
                "--", str(self.recorder("recorder")), str(marker), "0",
            ],
            env=environment, capture_output=True, text=True, timeout=30,
        )

        self.assertEqual(process.returncode, 70)
        self.assertFalse(marker.exists())

    def test_a_declared_executable_runs_as_the_file_that_was_protected_after_the_profile_moves(self):
        record, programs = self.run_across_profile_moves("declared", lambda declared, requested: [])

        self.assertEqual(record["calls"], ["P"] * 3)
        self.assertEqual(record["arguments"][:2], ["--omp", str(programs["P"])])
        self.assertEqual(record["held"], [str(programs["P"])])

    def test_an_explicit_executable_is_protected_and_pinned_in_every_spelling_as_the_only_effective_value(self):
        spellings = {
            "separate": (lambda declared, requested: ["--omp", str(requested)], "R"),
            "joined": (lambda declared, requested: [f"--omp={requested}"], "R"),
            "repeated": (lambda declared, requested: ["--omp", str(requested), f"--omp={declared}"], "P"),
        }
        for label, (supplied, effective) in spellings.items():
            with self.subTest(label):
                record, programs = self.run_across_profile_moves(label, supplied)

                self.assertEqual(record["calls"], [effective] * 3)
                self.assertEqual(record["arguments"][:2], ["--omp", str(programs[effective])])
                self.assertEqual([argument for argument in record["arguments"] if argument.startswith("--omp")], ["--omp"])
                self.assertEqual(record["held"], [str(programs[effective])])

    def test_an_exact_option_takes_precedence_over_a_longer_declared_name(self):
        """長い宣言名が先にある場合の完全一致名による実効fileの実行の検査"""
        longer = self.program(self.workspace / "longer", "X")
        default = self.program(self.workspace / "default", "P")
        requested = self.program(self.workspace / "requested", "R")
        record = self.workspace / "record"
        worker = self.script("both-executables", """\
import argparse, json, subprocess
from pathlib import Path
parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("record")
parser.add_argument("--omp", required=True)
parser.add_argument("--omp-x", required=True)
options = parser.parse_args()
Path(options.record).write_text(json.dumps({
    "omp": subprocess.check_output([options.omp], text=True).strip(),
    "omp-x": subprocess.check_output([options.omp_x], text=True).strip(),
}), encoding="utf-8")
""")

        status, message = self.run_job(
            "journal", [worker, record, "--omp", requested], executables={"omp-x": longer, "omp": default}
        )

        self.assertEqual(status, 0, message)
        self.assertEqual(json.loads(record.read_text(encoding="utf-8")), {"omp": "R", "omp-x": "X"})

    def test_an_abbreviated_or_valueless_executable_option_is_refused_before_anything_starts(self):
        declared = self.workspace / "declared"
        declared.symlink_to(self.program(self.workspace / "store", "P"))
        marker = self.workspace / "marker"
        refused = (["--om", str(declared)], [f"--om={declared}"], ["--o", str(declared)], ["--omp"], ["--omp="])
        for arguments in refused:
            with self.subTest(arguments):
                status, message = self.run_job(
                    "journal", [self.recorder("recorder"), marker, 0, *arguments], executables={"omp": declared}
                )

                self.assertEqual(status, 2)
                self.assertIn("--omp", message)
                self.assertFalse(marker.exists())
        self.assertFalse((self.runtime / "dotfiles-agent-job" / "journal.roots").exists())
        self.runs_again("journal", self.workspace / "after")

    def test_an_executable_that_cannot_be_protected_never_starts_the_worker(self):
        declared = self.workspace / "declared"
        declared.symlink_to(self.program(self.workspace / "store", "P"))
        marker = self.workspace / "marker"

        status, message = self.run_job(
            "journal", [self.recorder("recorder"), marker, 0], executables={"omp": declared}, environment={"FAKE_PROTECT_FAIL": "1"}
        )

        self.assertEqual(status, 70)
        self.assertIn("cannot protect the execution dependencies", message)
        self.assertFalse(marker.exists())

    def test_a_cancelled_job_ends_a_stalled_protection_and_its_descendants_before_releasing_the_roots_and_lock(self):
        job, record, pid_file, marker = self.start_with_stalled_protection(limit=60)
        wait_for(pid_file)

        job.send_signal(signal.SIGTERM)
        status, message = self.finish(job, timeout=20)

        self.assert_protection_ended_while_held(record, pid_file)
        self.assertEqual(status, 128 + signal.SIGTERM)
        self.assertIn("cancelled", message)
        self.assertFalse(marker.exists())
        self.runs_again("journal", self.workspace / "after")

    def test_the_deadline_ends_a_stalled_protection_and_its_descendants_before_releasing_the_roots_and_lock(self):
        job, record, pid_file, marker = self.start_with_stalled_protection(limit=3)

        status, message = self.finish(job, timeout=20)

        self.assert_protection_ended_while_held(record, pid_file)
        self.assertEqual(status, 124)
        self.assertIn("execution limit", message)
        self.assertFalse(marker.exists())
        self.runs_again("journal", self.workspace / "after")


if __name__ == "__main__":
    unittest.main()
