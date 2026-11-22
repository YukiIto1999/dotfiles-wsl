---
name: local-development
description: Brings a project checkout up in its own development environment so its app, API, or dev services can be used locally. Use when asked to start, run, or serve a project, bring up its database or other dev processes, or find which port, data directory, and devShell a local instance uses. Resolves the approved devShell through devenv or dotfiles-project-run, starts only the declared processes on explicit loopback ports with project-scoped data, confirms readiness, returns the endpoints, and stops only what it started. Not for host configuration or Nix generations, containers owned by tests, Orca worktree and terminal management, real-screen acceptance, or approving trust for a project's environment.
---

# project を自分の開発環境で起動する

対象 checkout を、その project が宣言した依存、port、data で使える状態にし、endpoint と停止方法を呼出し元へ返す。
起動したものの所有者を記録し、自分が起動したものだけを止める。

## 対象を固定する

1. checkout の絶対 path、branch または worktree、起動する app や service、呼出し元が必要とする URL や port、使う data（空、seed、既存）、使う期間を確かめる。
   Orca の worktree の作成や terminal の操作が要る場合は `orca-cli` に任せ、渡された worktree の path で続ける。
2. 同じ checkout で既に動いている instance を確かめる。
   devenv の project では `devenv processes list`、port は `ss -Hltnp 'sport = :PORT'` で listen している process を読む。
   既存の instance が使えるならそれを返し、利用者や他 session が起動した process を止めたり再起動したりしない。
3. 起動方法を、project の README、`devenv.nix`、`devenv.yaml`、`flake.nix` の devShell、`package.json` の script、`Procfile` などの宣言から選ぶ。
   宣言にない起動 command や port を推測で作らず、宣言が無い場合は不足として返す。

## 環境の入口を選ぶ

| project の宣言 | 入口 |
|---|---|
| `devenv.nix` の `processes` や `services` | `devenv up -d --strict-ports [PROCESS...]`、続けて `devenv processes wait --timeout 120` |
| `devenv.nix` の環境で動かす単発の command | `devenv shell -- COMMAND ARG...` |
| `.envrc` の `use flake` と flake の devShell | `dotfiles-project-run [--attr NAME] -- /usr/bin/env COMMAND ARG...` |

`dotfiles-project-run` は実行 file を絶対 path で受け取るため、devShell の `PATH` から command を探すには `/usr/bin/env` を挟む。
`.envrc` が未承認、拒否、存在しない場合、この入口は起動せず失敗し、host の環境へ戻らない。
承認は `.envrc` の内容を信頼する利用者の判断であり、`direnv allow` と `devenv allow` を代わりに実行しない。
`.envrc` と flake を読んで承認が必要な点を利用者へ示し、承認を待つ。
devShell の評価が lock の更新を要する場合も失敗するため、lock を書き換えずに不足として返す。

project が `compose.yaml` などの container を開発用の正規の起動方法として宣言し、利用者がその起動を求めた場合だけ、`docker compose -p 名前 up -d` で project 名を明示して起動する。
test が起動して破棄する container（Testcontainers など）は test の所有であり、このSkillでは起動しない。
共通の MCP や memory の背後にある container には触れない。

## port と data を project の内側に閉じる

- port は project が受け付ける変数や引数で明示し、devenv では `--strict-ports` で使用中の port を自動で別の値へずらさせない。
  `127.0.0.1` に bind させ、外部へ公開しない。
- Aspire Dashboard の `18888`〜`18890` と、AI CLI の telemetry collector の `4317`、`4318` は使わない。
- data は checkout の `.devenv/state`（devenv の `DEVENV_STATE`）か、project が宣言した local の領域に置く。
  共有や本番の database、他 project の data directory、利用者の既存 data を接続先にしない。
- seed、migration、reset のうち既存 data を消す操作は、この作業で作った data に限るか、利用者の承認を得てから行う。
- 資格情報は project の secret の仕組みから渡し、`.env` などの平文 file を新しく作らず、値を出力に出さない。

## 使える状態を確かめる

長く動く process は、harness の名前付き background service として起動し、ready の log か port を条件にする。
起動 command の終了値だけで使える状態とみなさず、次のどれかで確かめる。

- `devenv processes wait` の成功と `devenv processes list` の状態。
- project が定める health endpoint への `curl -fsS http://127.0.0.1:PORT/PATH`。
- `ss -Hltnp 'sport = :PORT'` で、自分が起動した process が listen していること。

失敗した場合は `devenv processes logs NAME -n 100` か起動した service の出力から、最初の error を返す。
依存の build や評価の失敗を、別の port、別の data、host の package で回避しない。

## 返却と停止

呼出し元へ、endpoint（URL と port）、起動した process と所有者（自分か既存か）、使った devShell と起動 command、data の場所、log の所在、停止の方法を返す。
UI の受入は `surface-operation`、実行時の遅延や停止の観測は `runtime-observation`、検査の実行は `change-verification` が、返した endpoint を使って続ける。
host の Nix、systemd、WSL の資源が原因で起動できない場合は、観測した error を `workstation-operations` へ渡す。

作業の終了時は、自分が起動したものだけを止める。
devenv は `devenv processes down`、container は起動に使った同じ project 名の `docker compose -p 名前 down`、harness の service は自分が付けた名前の service を止める。
volume や state directory は、この作業で作り、呼出し元が残すことを求めていない場合だけ消す。
既存の instance、他者の process、起動前からあった data は止めず、消さない。
