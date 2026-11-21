"""dotfiles-github-write を合成の GitHub API に向けて実行し、送った request を数える。

gh の開発用 host github.localhost は http の api.github.localhost を呼び、github.com と同じく
GH_TOKEN を使う。HTTP_PROXY でこの server へ寄せ、実 credential と外部 network を使わない。
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

COMMAND = sys.argv[1]
LOGINS = {
    "synthetic-token-a": "fixture-login-a",
    "synthetic-token-b": "fixture-login-b",
}
CALLER_TOKEN = "caller-token-must-not-be-used"
HEAD_SHA = "a" * 40
BASE_SHA = "b" * 40
REVIEW_SHA = "c" * 40

requests = []
lock = threading.Lock()


def read_body(handler):
    if handler.headers.get("Transfer-Encoding", "").lower() == "chunked":
        body = b""
        while True:
            size = int(handler.rfile.readline().split(b";")[0].strip(), 16)
            if size == 0:
                while handler.rfile.readline() not in (b"\r\n", b"\n", b""):
                    pass
                return body
            body += handler.rfile.read(size)
            handler.rfile.readline()
    length = int(handler.headers.get("Content-Length") or 0)
    return handler.rfile.read(length) if length else b""


def written(method, path, repo, payload):
    base = f"https://github.example/{repo}"
    parts = path.split("/")[4:]
    if method == "POST" and parts == ["issues"]:
        return {"id": 101, "number": 11, "html_url": f"{base}/issues/11", "state": "open", "extra": 1}
    if method == "POST" and parts == ["pulls"]:
        return {
            "id": 102,
            "number": 12,
            "html_url": f"{base}/pull/12",
            "state": "open",
            "draft": True,
            "head": {"ref": "topic/one", "sha": HEAD_SHA, "label": "fixture-fork:topic/one"},
            "base": {"ref": "main", "sha": BASE_SHA},
        }
    if method == "POST" and len(parts) == 3 and parts[0] == "issues" and parts[2] == "comments":
        return {"id": 103, "html_url": f"{base}/issues/{parts[1]}#issuecomment-103"}
    if method == "POST" and len(parts) == 3 and parts[0] == "pulls" and parts[2] == "reviews":
        return {
            "id": 104,
            "state": "APPROVED",
            "commit_id": REVIEW_SHA,
            "html_url": f"{base}/pull/{parts[1]}#pullrequestreview-104",
        }
    if method == "POST" and len(parts) == 5 and parts[:1] + parts[2:3] + parts[4:] == ["pulls", "comments", "replies"]:
        return {
            "id": 105,
            "in_reply_to_id": int(parts[3]),
            "html_url": f"{base}/pull/{parts[1]}#discussion_r105",
        }
    if method == "POST" and len(parts) == 3 and parts[0] == "pulls" and parts[2] == "requested_reviewers":
        return {
            "number": int(parts[1]),
            "html_url": f"{base}/pull/{parts[1]}",
            "requested_reviewers": [{"login": login} for login in payload.get("reviewers", [])],
            "requested_teams": [{"slug": slug} for slug in payload.get("team_reviewers", [])],
        }
    if method == "POST" and parts == ["git", "refs"]:
        return {"ref": payload["ref"], "node_id": "fixture", "object": {"sha": payload["sha"], "type": "commit"}}
    if method == "PATCH" and len(parts) == 2 and parts[0] == "issues":
        return {
            "id": 106,
            "number": int(parts[1]),
            "html_url": f"{base}/issues/{parts[1]}",
            "title": payload.get("title", "Existing title"),
            "state": payload.get("state", "open"),
            "state_reason": payload.get("state_reason"),
            "labels": [{"name": name, "id": 1} for name in payload.get("labels", [])],
            "assignees": [{"login": login, "id": 1} for login in payload.get("assignees", [])],
            "milestone": None if payload.get("milestone") is None else {"number": payload["milestone"]},
        }
    if method == "PATCH" and len(parts) == 3 and parts[:2] == ["issues", "comments"]:
        return {"id": int(parts[2]), "html_url": f"{base}#issuecomment-{parts[2]}", "updated_at": "2026-01-01T00:00:00Z"}
    if method == "PATCH" and len(parts) == 2 and parts[0] == "pulls":
        return {
            "id": 107,
            "number": int(parts[1]),
            "html_url": f"{base}/pull/{parts[1]}",
            "title": payload.get("title", "Existing title"),
            "state": payload.get("state", "open"),
            "maintainer_can_modify": payload.get("maintainer_can_modify", True),
            "head": {"ref": "topic/one", "sha": HEAD_SHA},
            "base": {"ref": payload.get("base", "main"), "sha": BASE_SHA},
        }
    return None


class Api(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_request(self):
        url = urlsplit(self.path)
        body = read_body(self)
        record = {
            "method": self.command,
            "host": url.netloc or self.headers.get("Host"),
            "path": url.path,
            "authorization": self.headers.get("Authorization"),
            "payload": json.loads(body) if body else None,
        }
        with lock:
            requests.append(record)

        token = (record["authorization"] or "").removeprefix("token ")
        status, reply = 404, {"message": "Not Found"}
        if token not in LOGINS:
            status, reply = 401, {"message": "Bad credentials"}
        elif self.command == "GET" and url.path == "/user":
            status, reply = 200, {"login": LOGINS[token], "id": 1}
        elif self.command in ("POST", "PATCH") and url.path.startswith("/repos/"):
            repo = "/".join(url.path.split("/")[2:4])
            if repo == "fixture-org/unstable":
                status, reply = 502, {"message": "Server Error"}
            else:
                result = written(self.command, url.path, repo, record["payload"] or {})
                if result is not None:
                    status, reply = (201 if self.command == "POST" else 200), result

        data = json.dumps(reply).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = handle_request
    do_POST = handle_request
    do_PATCH = handle_request

    def log_message(self, format, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Api)
threading.Thread(target=server.serve_forever, daemon=True).start()

work = tempfile.mkdtemp()
caller_config = os.path.join(work, "caller-gh")
os.mkdir(caller_config)
caller_hosts = os.path.join(caller_config, "hosts.yml")
hosts_text = (
    "github.localhost:\n"
    f"    oauth_token: {CALLER_TOKEN}\n"
    "    user: caller\n"
    "github.com:\n"
    f"    oauth_token: {CALLER_TOKEN}\n"
    "    user: caller\n"
)
with open(caller_hosts, "w") as handle:
    handle.write(hosts_text)

base_env = {
    "PATH": os.environ["PATH"],
    "HOME": work,
    "TMPDIR": work,
    "HTTP_PROXY": f"http://127.0.0.1:{server.server_address[1]}",
}
# 呼出し元が別 account や host を指す GitHub 用の環境を持っていても、命令はそれを借りない
hostile_env = {
    "GH_TOKEN": CALLER_TOKEN,
    "GITHUB_TOKEN": CALLER_TOKEN,
    "GH_ENTERPRISE_TOKEN": CALLER_TOKEN,
    "GITHUB_ENTERPRISE_TOKEN": CALLER_TOKEN,
    "GH_HOST": "caller.example",
    "GH_REPO": "caller/repo",
    "GH_CONFIG_DIR": caller_config,
    "XDG_CONFIG_HOME": work,
    "GH_DEBUG": "api",
    "DEBUG": "api",
}

failures = []


def write_file(name, text):
    path = os.path.join(work, name)
    with open(path, "w") as handle:
        handle.write(text)
    return path


def run(name, args, expect_status, expect_requests, stdin="", env=None, receipt=None):
    with lock:
        start = len(requests)
    completed = subprocess.run(
        [COMMAND, *args],
        input=stdin,
        capture_output=True,
        text=True,
        env={**base_env, **(env or {})},
        timeout=60,
    )
    with lock:
        seen = requests[start:]

    def failed(reason):
        failures.append(f"{name}: {reason}\nstdout={completed.stdout!r}\nstderr={completed.stderr!r}")

    if completed.returncode != expect_status:
        failed(f"exit {completed.returncode}, expected {expect_status}")
    if expect_status == 0 and completed.stderr:
        failed("unexpected diagnostic on successful write")
    actual = [
        {key: value for key, value in record.items() if key != "authorization"} for record in seen
    ]
    if actual != [{"host": "api.github.localhost", **entry} for entry in expect_requests]:
        failed(f"requests {json.dumps(actual)}")
    tokens = {record["authorization"] for record in seen}
    if len(tokens) > 1:
        failed(f"mixed credentials {sorted(map(str, tokens))}")
    for secret in [CALLER_TOKEN, *LOGINS]:
        if secret in completed.stdout or secret in completed.stderr:
            failed("a token reached the output")
    if receipt is not None:
        try:
            parsed = json.loads(completed.stdout)
        except json.JSONDecodeError:
            parsed = None
        if parsed != receipt:
            failed(f"receipt {completed.stdout!r}")
    return seen


user = {"method": "GET", "path": "/user", "payload": None}


def post(path, payload):
    return {"method": "POST", "path": path, "payload": payload}


def patch(path, payload):
    return {"method": "PATCH", "path": path, "payload": payload}


def check_credential(name, seen, token):
    if any(record["authorization"] != f"token {token}" for record in seen):
        failures.append(f"{name}: request did not use {token}")


identity_a = ["--account", "fixture-a", "--login", "fixture-login-a"]
identity_b = ["--account", "fixture-b", "--login", "fixture-login-b"]
body = write_file("body.md", "Fixture body\n")
comments = write_file(
    "comments.json",
    json.dumps([{"path": "src/main.c", "line": 3, "side": "RIGHT", "body": "Use the helper"}]),
)

# 書込: 借りられる環境が揃っていても、選んだ account の token で一度だけ送る
seen = run(
    "comment-ignores-caller-credentials",
    [*identity_b, "comment", "--repo", "fixture-org/demo", "--number", "7", "--body-file", "-"],
    0,
    [user, post("/repos/fixture-org/demo/issues/7/comments", {"body": "Fixture comment\n"})],
    stdin="Fixture comment\n",
    env=hostile_env,
    receipt={
        "account": "fixture-b",
        "login": "fixture-login-b",
        "operation": "comment",
        "result": {"id": 103, "html_url": "https://github.example/fixture-org/demo/issues/7#issuecomment-103"},
    },
)
check_credential("comment-ignores-caller-credentials", seen, "synthetic-token-b")
with open(caller_hosts) as handle:
    if handle.read() != hosts_text or os.listdir(caller_config) != ["hosts.yml"]:
        failures.append("caller gh configuration changed")

seen = run(
    "issue-create",
    [*identity_a, "issue-create", "--repo", "fixture-org/demo", "--title", "Fixture issue", "--body-file", body],
    0,
    [user, post("/repos/fixture-org/demo/issues", {"title": "Fixture issue", "body": "Fixture body\n"})],
    receipt={
        "account": "fixture-a",
        "login": "fixture-login-a",
        "operation": "issue-create",
        "result": {
            "id": 101,
            "number": 11,
            "html_url": "https://github.example/fixture-org/demo/issues/11",
            "state": "open",
        },
    },
)
check_credential("issue-create", seen, "synthetic-token-a")

run(
    "issue-create-without-body",
    [*identity_a, "issue-create", "--repo", "fixture-org/demo", "--title", "Title only"],
    0,
    [user, post("/repos/fixture-org/demo/issues", {"title": "Title only"})],
)

run(
    "pr-create",
    [
        *identity_a,
        "pr-create",
        "--repo",
        "fixture-org/demo",
        "--title",
        "Fixture change",
        "--head",
        "fixture-fork:topic/one",
        "--base",
        "main",
        "--body-file",
        body,
        "--draft",
    ],
    0,
    [
        user,
        post(
            "/repos/fixture-org/demo/pulls",
            {
                "title": "Fixture change",
                "head": "fixture-fork:topic/one",
                "base": "main",
                "draft": True,
                "body": "Fixture body\n",
            },
        ),
    ],
    receipt={
        "account": "fixture-a",
        "login": "fixture-login-a",
        "operation": "pr-create",
        "result": {
            "id": 102,
            "number": 12,
            "html_url": "https://github.example/fixture-org/demo/pull/12",
            "state": "open",
            "draft": True,
            "head": {"ref": "topic/one", "sha": HEAD_SHA},
            "base": {"ref": "main", "sha": BASE_SHA},
        },
    },
)

run(
    "review",
    [
        *identity_a,
        "review",
        "--repo",
        "fixture-org/demo",
        "--number",
        "12",
        "--commit",
        REVIEW_SHA,
        "--event",
        "APPROVE",
        "--comments-file",
        comments,
    ],
    0,
    [
        user,
        post(
            "/repos/fixture-org/demo/pulls/12/reviews",
            {"commit_id": REVIEW_SHA, "event": "APPROVE", "comments": json.loads(open(comments).read())},
        ),
    ],
    receipt={
        "account": "fixture-a",
        "login": "fixture-login-a",
        "operation": "review",
        "result": {
            "id": 104,
            "state": "APPROVED",
            "commit_id": REVIEW_SHA,
            "html_url": "https://github.example/fixture-org/demo/pull/12#pullrequestreview-104",
        },
    },
)

run(
    "review-reply",
    [*identity_b, "review-reply", "--repo", "fixture-org/demo", "--number", "12", "--comment-id", "55", "--body-file", body],
    0,
    [user, post("/repos/fixture-org/demo/pulls/12/comments/55/replies", {"body": "Fixture body\n"})],
)

# 通常の更新: 指定した field だけを送り、省いた field は payload に入れない
run(
    "issue-update",
    [
        *identity_a,
        "issue-update",
        "--repo",
        "fixture-org/demo",
        "--number",
        "7",
        "--state",
        "closed",
        "--state-reason",
        "completed",
        "--labels-json",
        '["bug", "needs triage"]',
        "--assignees-json",
        '["fixture-login-a"]',
        "--milestone",
        "3",
    ],
    0,
    [
        user,
        patch(
            "/repos/fixture-org/demo/issues/7",
            {
                "state": "closed",
                "state_reason": "completed",
                "labels": ["bug", "needs triage"],
                "assignees": ["fixture-login-a"],
                "milestone": 3,
            },
        ),
    ],
    receipt={
        "account": "fixture-a",
        "login": "fixture-login-a",
        "operation": "issue-update",
        "result": {
            "id": 106,
            "number": 7,
            "html_url": "https://github.example/fixture-org/demo/issues/7",
            "state": "closed",
            "state_reason": "completed",
            "title": "Existing title",
            "labels": ["bug", "needs triage"],
            "assignees": ["fixture-login-a"],
            "milestone": 3,
        },
    },
)

run(
    "issue-update-clears",
    [*identity_a, "issue-update", "--repo", "fixture-org/demo", "--number", "7", "--labels-json", "[]", "--milestone", "none"],
    0,
    [user, patch("/repos/fixture-org/demo/issues/7", {"labels": [], "milestone": None})],
)

run(
    "issue-update-text",
    [*identity_b, "issue-update", "--repo", "fixture-org/demo", "--number", "7", "--title", "New title", "--body-file", body],
    0,
    [user, patch("/repos/fixture-org/demo/issues/7", {"title": "New title", "body": "Fixture body\n"})],
)

run(
    "comment-edit",
    [*identity_a, "comment-edit", "--repo", "fixture-org/demo", "--comment-id", "56", "--body-file", body],
    0,
    [user, patch("/repos/fixture-org/demo/issues/comments/56", {"body": "Fixture body\n"})],
    receipt={
        "account": "fixture-a",
        "login": "fixture-login-a",
        "operation": "comment-edit",
        "result": {
            "id": 56,
            "html_url": "https://github.example/fixture-org/demo#issuecomment-56",
            "updated_at": "2026-01-01T00:00:00Z",
        },
    },
)

run(
    "pr-update",
    [
        *identity_a,
        "pr-update",
        "--repo",
        "fixture-org/demo",
        "--number",
        "12",
        "--title",
        "Renamed change",
        "--base",
        "release",
        "--maintainer-can-modify",
        "false",
    ],
    0,
    [
        user,
        patch(
            "/repos/fixture-org/demo/pulls/12",
            {"title": "Renamed change", "base": "release", "maintainer_can_modify": False},
        ),
    ],
    receipt={
        "account": "fixture-a",
        "login": "fixture-login-a",
        "operation": "pr-update",
        "result": {
            "id": 107,
            "number": 12,
            "html_url": "https://github.example/fixture-org/demo/pull/12",
            "state": "open",
            "title": "Renamed change",
            "maintainer_can_modify": False,
            "head": {"ref": "topic/one", "sha": HEAD_SHA},
            "base": {"ref": "release", "sha": BASE_SHA},
        },
    },
)

run(
    "pr-reviewers",
    [
        *identity_a,
        "pr-reviewers",
        "--repo",
        "fixture-org/demo",
        "--number",
        "12",
        "--reviewers-json",
        '["fixture-reviewer"]',
        "--team-reviewers-json",
        '["fixture-team"]',
    ],
    0,
    [
        user,
        post(
            "/repos/fixture-org/demo/pulls/12/requested_reviewers",
            {"reviewers": ["fixture-reviewer"], "team_reviewers": ["fixture-team"]},
        ),
    ],
    receipt={
        "account": "fixture-a",
        "login": "fixture-login-a",
        "operation": "pr-reviewers",
        "result": {
            "number": 12,
            "html_url": "https://github.example/fixture-org/demo/pull/12",
            "requested_reviewers": ["fixture-reviewer"],
            "requested_teams": ["fixture-team"],
        },
    },
)

run(
    "branch-create",
    [*identity_b, "branch-create", "--repo", "fixture-org/demo", "--branch", "topic/two", "--from-sha", HEAD_SHA],
    0,
    [user, post("/repos/fixture-org/demo/git/refs", {"ref": "refs/heads/topic/two", "sha": HEAD_SHA})],
    receipt={
        "account": "fixture-b",
        "login": "fixture-login-b",
        "operation": "branch-create",
        "result": {"ref": "refs/heads/topic/two", "sha": HEAD_SHA},
    },
)

# 応答のない書込は一度で止め、再送しない
run(
    "unconfirmed-write-is-not-retried",
    [*identity_a, "comment", "--repo", "fixture-org/unstable", "--number", "1", "--body-file", body],
    4,
    [user, post("/repos/fixture-org/unstable/issues/1/comments", {"body": "Fixture body\n"})],
)

# identity: account の token が名乗る login と完全に一致しなければ書かない
for name, args in [
    ("other-login", ["--account", "fixture-a", "--login", "fixture-login-b"]),
    ("login-case", ["--account", "fixture-a", "--login", "Fixture-Login-A"]),
]:
    run(
        f"identity-{name}",
        [*args, "comment", "--repo", "fixture-org/demo", "--number", "7", "--body-file", body],
        3,
        [user],
    )

# credential: 読めない token では何も送らない
for account in ["fixture-empty", "fixture-missing"]:
    run(
        f"credential-{account}",
        ["--account", account, "--login", "fixture-login-a", "comment", "--repo", "fixture-org/demo", "--number", "7", "--body-file", body],
        3,
        [],
    )

blank = write_file("blank.md", " \n\t\n")
bad_comments = write_file("bad-comments.json", json.dumps([{"path": "a.c", "body": "x"}]))
two_values = write_file("two-values.json", "[] []")
comment_args = ["comment", "--repo", "fixture-org/demo", "--number", "7", "--body-file", body]
review_args = ["review", "--repo", "fixture-org/demo", "--number", "7", "--commit", REVIEW_SHA]

# 許可していない操作と不正な入力は network へ出ない
rejected = {
    "unknown-account": ["--account", "fixture-c", "--login", "fixture-login-a", *comment_args],
    "account-shape": ["--account", "Fixture-A", "--login", "fixture-login-a", *comment_args],
    "missing-login": ["--account", "fixture-a", *comment_args],
    "merge": [*identity_a, "merge", "--repo", "fixture-org/demo", "--number", "7"],
    "no-operation": identity_a,
    "two-operations": [*identity_a, "comment", "comment", "--repo", "fixture-org/demo", "--number", "7", "--body-file", body],
    "dot-repo": [*identity_a, "comment", "--repo", "fixture-org/..", "--number", "7", "--body-file", body],
    "path-repo": [*identity_a, "comment", "--repo", "fixture-org/demo/issues", "--number", "7", "--body-file", body],
    "zero-number": [*identity_a, "comment", "--repo", "fixture-org/demo", "--number", "0", "--body-file", body],
    "repeated-option": [*identity_a, *comment_args, "--repo", "fixture-org/other"],
    "foreign-option": [*identity_a, *comment_args, "--title", "x"],
    "draft-comment": [*identity_a, *comment_args, "--draft"],
    "blank-comment": [*identity_a, "comment", "--repo", "fixture-org/demo", "--number", "7", "--body-file", blank],
    "missing-body": [*identity_a, "comment", "--repo", "fixture-org/demo", "--number", "7", "--body-file", os.path.join(work, "absent")],
    "pending-review": [*identity_a, *review_args],
    "pending-event": [*identity_a, *review_args, "--event", "PENDING"],
    "comment-review-without-body": [*identity_a, *review_args, "--event", "COMMENT"],
    "short-commit": [*identity_a, "review", "--repo", "fixture-org/demo", "--number", "7", "--commit", "abc123", "--event", "APPROVE"],
    "review-comment-without-line": [*identity_a, *review_args, "--event", "APPROVE", "--comments-file", bad_comments],
    "review-comments-two-values": [*identity_a, *review_args, "--event", "APPROVE", "--comments-file", two_values],
    "branch-with-space": [*identity_a, "pr-create", "--repo", "fixture-org/demo", "--title", "x", "--head", "bad branch", "--base", "main"],
    "blank-title": [*identity_a, "issue-create", "--repo", "fixture-org/demo", "--title", "  "],
    "empty-value": [*identity_a, "issue-update", "--repo", "fixture-org/demo", "--number", "7", "--body-file", ""],
    "update-without-fields": [*identity_a, "issue-update", "--repo", "fixture-org/demo", "--number", "7"],
    "pr-update-without-fields": [*identity_a, "pr-update", "--repo", "fixture-org/demo", "--number", "7"],
    "reviewers-without-fields": [*identity_a, "pr-reviewers", "--repo", "fixture-org/demo", "--number", "7"],
    "state-word-list": [*identity_a, "issue-update", "--repo", "fixture-org/demo", "--number", "7", "--state", "open closed"],
    "state-reason": [*identity_a, "issue-update", "--repo", "fixture-org/demo", "--number", "7", "--state-reason", "spam"],
    "labels-object": [*identity_a, "issue-update", "--repo", "fixture-org/demo", "--number", "7", "--labels-json", '{"name": "bug"}'],
    "labels-empty-name": [*identity_a, "issue-update", "--repo", "fixture-org/demo", "--number", "7", "--labels-json", '[""]'],
    "milestone-word": [*identity_a, "issue-update", "--repo", "fixture-org/demo", "--number", "7", "--milestone", "next"],
    "pr-state-merged": [*identity_a, "pr-update", "--repo", "fixture-org/demo", "--number", "7", "--state", "merged"],
    "pr-update-draft": [*identity_a, "pr-update", "--repo", "fixture-org/demo", "--number", "7", "--title", "x", "--draft"],
    "maintainer-word": [*identity_a, "pr-update", "--repo", "fixture-org/demo", "--number", "7", "--maintainer-can-modify", "yes"],
    "pr-update-head": [*identity_a, "pr-update", "--repo", "fixture-org/demo", "--number", "7", "--head", "other"],
    "blank-comment-edit": [*identity_a, "comment-edit", "--repo", "fixture-org/demo", "--comment-id", "56", "--body-file", blank],
    "branch-short-sha": [*identity_a, "branch-create", "--repo", "fixture-org/demo", "--branch", "topic", "--from-sha", "abc123"],
    "branch-full-ref": [*identity_a, "branch-create", "--repo", "fixture-org/demo", "--branch", "refs/heads/topic", "--from-sha", HEAD_SHA],
    "branch-delete": [*identity_a, "branch-delete", "--repo", "fixture-org/demo", "--branch", "topic"],
    "pr-merge": [*identity_a, "pr-merge", "--repo", "fixture-org/demo", "--number", "7"],
    "api-passthrough": [*identity_a, "api", "repos/fixture-org/demo/git/refs/heads/main", "--method", "PATCH"],
}
for name, args in rejected.items():
    run(f"rejected-{name}", args, 2, [], env=hostile_env)

server.shutdown()
if failures:
    print("\n\n".join(failures), file=sys.stderr)
    sys.exit(1)
