# 記憶の収穫

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

omp の session 記録から、利用者の訂正、決定、好みのうち将来の判断を変えるものを取り出し、project memory へ保存する。client は会話を自動で保存しないため、明示的な`memory_save`で残さなかった訂正はこの収穫が拾う。

## 前提

`project-memory` Capability と omp が有効な host だけに配備する。保存先は session の cwd から決まる project scope で、cwd が Git の work tree でない session は読まない。

## timer

`dotfiles-agent-memory-harvest.timer` は毎日 07:00 に起動し、前回成功した実行から今回の開始までの利用者の発言を読む。初回は 7 日前から読む。1 回の実行は 6 時間で打ち切る。WSL が止まっていて起動を逃した場合は、次に起動したときに実行する。

```sh
systemctl status dotfiles-agent-memory-harvest.timer
journalctl -u dotfiles-agent-memory-harvest.service -n 50
```

log の各行は候補ごとの結果である。

| 行 | 意味 |
|---|---|
| `saved:` | status で保存を確かめた |
| `pending:`、`indeterminate:` | 保存を確かめていない。次の実行で status を確かめる |
| `duplicate:` | 保存済みの記憶と同じ内容なので保存しなかった |
| `no-situation:` | 将来の別 session で同じ判断を迫られる場面を model が書かなかったので保存しなかった |
| `rejected:` | 資格情報や個人情報に見えるため、runtime が保存を拒んだ |
| `skipped:` | cwd から Git project を決められない session を読まなかった |

model の呼び出し、一覧、保存のいずれかが失敗すると service は非ゼロで終わり、`dotfiles-doctor` の `maintenance/dotfiles-agent-memory-harvest.timer` に現れる。読み終えた位置は進めないので、次の実行が同じ範囲を読み直す。保存済みの発言は読み直しでも model へ渡さない。前回の`pending`が status で失敗した場合は、log の source が指す発言を確かめ、残すなら`memory` Skill で明示的に保存する。

## 状態

読み終えた位置と確認待ちの receipt は `~/.local/state/dotfiles-wsl/memory-harvest.json` にある。file を消すと、次の実行は 7 日前から読み直し、確認待ちの receipt を確かめなくなる。

## 手動で実行する

timer を待たずに実行する。

```sh
dotfiles-agent-memory-harvest
```

project に保存済みの記憶は、checkout の root で一覧できる。

```sh
printf '{"cwd":"%s","scope":"project"}' "$PWD" | dotfiles-memory curated | jq '.memories[] | {kind, source, content}'
```

model に渡す情報、判定の梯子、信頼境界は [AI tooling](../architecture/ai-tooling.md#記憶の収穫)を参照する。
