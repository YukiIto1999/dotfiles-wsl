"""supervisor の計測の一行を repository と command ごとに集計する、手で呼ぶ script

journald の dotfiles-supervise の計測を鍵ごとに集計する。子プロセスの終了と監督器の取消を分け、検査の合否は判定しない。

使い方: python3 summarize-runs.py SINCE
  SINCE: journalctl の --since へ渡す値。例は '2026-11-18'、'2 days ago'
"""

import argparse
import json
import statistics
import subprocess
import sys
from collections import defaultdict

HEADER = ("stage", "repository", "command", "runs", "client_zero", "client_nonzero", "other_or_unknown", "zero_median_s", "zero_max_s",
          "wait_total_s", "slot_wait_total_s", "target_overrun", "slot_wait_samples")


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
    制約: 全走行の実行枠の待ちを計測できた鍵に限る合計秒の表示
    """
    groups = defaultdict(list)
    for key, record in keyed:
        groups[key].append(record)
    rows = []
    for (stage, repository, command), records in sorted(groups.items(), key=lambda item: (item[0][1], item[0][2], item[0][0])):
        completed = [record for record in records
                     if record.get("admitted") is True and record.get("cancelled") is False
                     and type(record.get("client_status")) is int
                     and record.get("status") == (record["client_status"] if record["client_status"] >= 0 else 128 - record["client_status"])]
        zero = [record for record in completed if record["client_status"] == 0]
        run_times = [record["runSeconds"] for record in zero if is_number(record.get("runSeconds"))]
        slot_waits = [record["slotWaitSeconds"] for record in records if is_number(record.get("slotWaitSeconds"))]
        overrun = [record for record in records
                   if is_number(record.get("targetSeconds")) and is_number(record.get("runSeconds"))
                   and record["runSeconds"] > record["targetSeconds"]]
        rows.append((
            stage, repository, command, str(len(records)), str(len(zero)),
            str(len(completed) - len(zero)), str(len(records) - len(completed)),
            seconds(statistics.median(run_times) if run_times else None), seconds(max(run_times) if run_times else None),
            seconds(sum(record["waitSeconds"] for record in records if is_number(record.get("waitSeconds")))),
            seconds(sum(slot_waits) if len(slot_waits) == len(records) else None),
            str(len(overrun)), str(len(slot_waits)),
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
