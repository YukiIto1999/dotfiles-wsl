import argparse
import os
import sqlite3
import subprocess
import sys
import uuid
from pathlib import Path


def text(value):
    value = value.strip()
    if not value or not value.isprintable():
        raise argparse.ArgumentTypeError("expected a non-empty single line")
    return value


def project():
    result = subprocess.run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True, check=False,
    )
    return str(Path(result.stdout.rstrip("\n")).resolve() if result.returncode == 0 else Path.cwd())


def main():
    parser = argparse.ArgumentParser(prog="dotfiles-agent-brief", description="Keep requested outcomes across changes of plan, worktree and agent. Store references, not private transcripts or credentials.")
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("list", help="list open briefs for this repository without choosing one")
    for action, help_text in (
        ("new", "start a brief; print its ID"), ("add", "record additional requested outcomes"),
        ("show", "read the whole brief, including unassigned outcomes"),
        ("note", "record the owner, next action or blocker without accepting an outcome"),
        ("accept", "accept one outcome with observed evidence"),
        ("withdraw", "withdraw one outcome with the user's decision reference"),
        ("reopen", "reopen an outcome with the reason"),
        ("forget", "discard a finished brief"),
    ):
        sub = commands.add_parser(action, help=help_text)
        if action != "new":
            sub.add_argument("case")
        if action in ("new", "add"):
            sub.add_argument("source", type=text)
            sub.add_argument("outcomes", type=text, nargs="+")
        if action in ("note", "accept", "withdraw", "reopen"):
            sub.add_argument("item", type=int)
            sub.add_argument("reference", type=text)
    args = parser.parse_args()
    os.umask(0o077)
    directory = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "dotfiles-agent/briefs"
    path = directory / "cases.sqlite3"
    action = args.action
    if action == "new":
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    elif not path.exists():
        if action == "list":
            return
        raise ValueError("no such brief")
    mode = "ro" if action in ("list", "show") else "rwc" if action == "new" else "rw"
    with sqlite3.connect(f"{path.resolve().as_uri()}?mode={mode}", uri=True) as db:
        db.execute("PRAGMA foreign_keys=ON")
        if action not in ("list", "show"):
            db.execute("BEGIN IMMEDIATE")
        if action == "new":
            db.execute("CREATE TABLE IF NOT EXISTS cases (id TEXT PRIMARY KEY, project TEXT NOT NULL)")
            db.execute("""CREATE TABLE IF NOT EXISTS outcomes (
                brief TEXT REFERENCES cases(id) ON DELETE CASCADE, item INTEGER, source TEXT NOT NULL,
                outcome TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open', reference TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(brief,item))""")
            args.case = uuid.uuid4().hex
            db.execute("INSERT INTO cases VALUES (?,?)", (args.case, project()))
        if action == "list":
            for row in db.execute("""SELECT c.id, o.source, o.outcome FROM cases c JOIN outcomes o
                ON c.id=o.brief AND o.item=1 WHERE c.project=? AND EXISTS
                (SELECT 1 FROM outcomes x WHERE x.brief=c.id AND x.status='open') ORDER BY c.rowid""", (project(),)):
                print(*row, sep="\t")
            return
        case = args.case
        if not db.execute("SELECT 1 FROM cases WHERE id=?", (case,)).fetchone():
            raise ValueError("no such brief")
        if action in ("new", "add"):
            first = db.execute("SELECT coalesce(max(item),0)+1 FROM outcomes WHERE brief=?", (case,)).fetchone()[0]
            db.executemany("INSERT INTO outcomes (brief,item,source,outcome) VALUES (?,?,?,?)",
                           ((case, i, args.source, outcome) for i, outcome in enumerate(args.outcomes, first)))
            if action == "new":
                print(case)
                return
        elif action == "forget":
            if db.execute("SELECT 1 FROM outcomes WHERE brief=? AND status='open' LIMIT 1", (case,)).fetchone():
                raise ValueError("brief still has open outcomes")
            db.execute("DELETE FROM cases WHERE id=?", (case,))
            return
        elif action != "show":
            status = {"note": "open", "accept": "done", "withdraw": "withdrawn", "reopen": "open"}[action]
            updated = db.execute("""UPDATE outcomes SET status=?, reference=? WHERE brief=? AND item=?
                AND (status='open')=?""", (status, args.reference, case, args.item, action != "reopen"))
            if updated.rowcount != 1:
                raise ValueError("unknown item or invalid transition; show the brief first")
        print(f"Brief: {case}")
        for item, status, outcome, source, reference in db.execute(
            "SELECT item,status,outcome,source,reference FROM outcomes WHERE brief=? ORDER BY item", (case,)
        ):
            print(f"{item} [{status}] {outcome} ({source})" + (f" — {reference}" if reference else ""))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, sqlite3.Error) as exc:
        sys.exit(f"dotfiles-agent-brief: {exc}")
