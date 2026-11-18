"""supervisor の計測の一行を repository と command ごとに集計する、手で呼ぶ script

journald の dotfiles-supervise の計測を読み、鍵（区分、repository の根、command）ごとに、走行の数、合格、検査の失敗、判定なし、
合格した走行の秒の中央値と最大、待ちの合計、実行枠の待ちの合計、時間の目標を超えた走行の数を、タブ区切りで出す。
package にも検査にも入れず、資源の扱いを変える前後を比べるときに手元で動かす。

使い方: python3 summarize-runs.py SINCE
  SINCE: journalctl の --since へ渡す値。例は '2026-11-18'、'2 days ago'
"""

import argparse
import json
import statistics
import subprocess
import sys
from collections import defaultdict

# 検査の合否を表さない終了status。75 は入場できなかった未実行、124 は走行の期限切れ、143 は取消。これ以外の0でない status は検査の失敗
NO_VERDICT = (75, 124, 143)
HEADER = ("stage", "repository", "command", "runs", "pass", "failure", "no_verdict", "pass_median_s", "pass_max_s",
          "wait_total_s", "slot_wait_total_s", "target_overrun")


def is_number(value):
    """記録の数値の項目か。真偽値は数に含めない"""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def read_records(text):
    """journalctl -o cat の出力から、入れ子でない走行の計測の一行を読む

    text: journalctl の出力。一行が一件の MESSAGE
    戻り値: 鍵を三行で持つ記録の（鍵の三行、記録）の一覧と、鍵が無いか三行でない記録の数
    制約: 入れ子の走行は外側の走行とは別の行になるため集計に入れない。鍵の無い走行は repository と command に分けられない
    """
    keyed, keyless = [], 0
    for line in text.splitlines():
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict) or record.get("event") != "workload" or record.get("nested"):
            continue
        parts = (record.get("key") or "").split("\n")
        if len(parts) == 3:
            keyed.append((tuple(parts), record))
        else:
            keyless += 1
    return keyed, keyless


def seconds(value):
    """秒を一桁で書く。値が無ければ -"""
    return "-" if value is None else f"{value:.1f}"


def summarize(keyed):
    """鍵ごとの集計の行

    keyed: read_records が返した（鍵の三行、記録）の一覧
    戻り値: HEADER と同じ並びの文字列の行を、repository、command、区分の順に並べた一覧
    制約: 実行枠の待ちを持つ記録が無い鍵は - にする。枠の待ちを記録する前の走行を、待たなかった 0 と混ぜないため
    """
    groups = defaultdict(list)
    for key, record in keyed:
        groups[key].append(record)
    rows = []
    for (stage, repository, command), records in sorted(groups.items(), key=lambda item: (item[0][1], item[0][2], item[0][0])):
        passed = [record for record in records if record.get("status") == 0]
        no_verdict = [record for record in records if record.get("status") in NO_VERDICT]
        run_times = [record["runSeconds"] for record in passed if is_number(record.get("runSeconds"))]
        slot_waits = [record["slotWaitSeconds"] for record in records if is_number(record.get("slotWaitSeconds"))]
        overrun = [record for record in records
                   if is_number(record.get("targetSeconds")) and is_number(record.get("runSeconds"))
                   and record["runSeconds"] > record["targetSeconds"]]
        rows.append((
            stage, repository, command, str(len(records)), str(len(passed)),
            str(len(records) - len(passed) - len(no_verdict)), str(len(no_verdict)),
            seconds(statistics.median(run_times) if run_times else None), seconds(max(run_times) if run_times else None),
            seconds(sum(record["waitSeconds"] for record in records if is_number(record.get("waitSeconds")))),
            seconds(sum(slot_waits) if slot_waits else None),
            str(len(overrun)),
        ))
    return rows


def main(arguments):
    """計測の一行を journald から読んで集計を標準出力へ出す

    arguments: SINCE を一つ持つ引数
    戻り値: journalctl が失敗した場合はその status、それ以外は 0
    """
    parser = argparse.ArgumentParser(prog="summarize-runs.py", description="Summarize the dotfiles-supervise measurements per repository and command.")
    parser.add_argument("since", help="value for journalctl --since, such as '2026-11-18' or '2 days ago'")
    options = parser.parse_args(arguments)
    try:
        result = subprocess.run(
            ["journalctl", "--user", "-t", "dotfiles-supervise", "-o", "cat", "--no-pager", f"--since={options.since}"],
            capture_output=True, text=True, check=False)
    except OSError as error:
        print(f"summarize-runs.py: cannot run journalctl: {error}", file=sys.stderr)
        return 1
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        return result.returncode
    keyed, keyless = read_records(result.stdout)
    print("\t".join(HEADER))
    for row in summarize(keyed):
        print("\t".join(row))
    print(f"\nrecords: {len(keyed)} with a three-line key, {keyless} without one (not summarized)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
