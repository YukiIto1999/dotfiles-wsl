# 記憶の収穫

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

omp の session 記録から、利用者の訂正、決定、好みのうち将来の判断を変えるものを取り出し、project memory へ保存する。client は会話を自動で保存しないため、明示的な`memory_save`で残さなかった訂正はこの収穫が拾う。

## 前提

`dotfiles.agents.memoryHarvest.enable = true`を宣言し、`project-memory` CapabilityとOMPを採用したhostだけに配備する。
既定では無効であり、新しいPCで利用者発言の外部modelへの送信を自動で始めない。
保存先はsessionのcwdから決まるproject scopeで、cwdがGitのworktreeでないsessionは読まない。

## timer

`dotfiles-agent-memory-harvest.timer` は user manager の timer で、毎日 07:00 に同名の user service を起動する。service は`agents.slice`の中で動き、前回成功した実行から今回の開始までの利用者の発言を読む。初回は 7 日前から読む。WSL が止まっていて起動を逃した場合は、次に user manager が起動したときに実行する。

```sh
systemctl --user status dotfiles-agent-memory-harvest.timer
journalctl --user -u dotfiles-agent-memory-harvest.service -n 50
```

log の各行は候補ごとの結果である。

| 行 | 意味 |
|---|---|
| `saved:` | backend が保存を確定した。`save`か`status`が、operation の完了と document の存在を確かめて返した |
| `pending:`、`indeterminate:` | 保存を確かめていない。次の実行で status を確かめる |
| `duplicate:` | 保存済みの記憶と同じ内容なので保存しなかった |
| `no-situation:` | 将来の別 session で同じ判断を迫られる場面を model が書かなかったので保存しなかった |
| `rejected:` | 資格情報や個人情報に見えるため、runtime が保存を拒んだ |
| `excluded:` | modelへの送信前検査で発言または保存済みの記憶を除外した。本文はlogへ出さない |
| `skipped:` | cwd から Git project を決められない session を読まなかった |

送信前検査、modelの呼び出し、一覧、保存、確認のいずれかが失敗するとserviceは非ゼロで終わり、`dotfiles-doctor`の`maintenance/dotfiles-agent-memory-harvest.timer`に現れる。この observation は user manager の unit を読むので、`dotfiles-doctor` は収穫を動かす user で、`XDG_RUNTIME_DIR` のある login session から実行する。user manager に届かない場合は、system manager の同名 unit を代わりに読まず、観測の失敗として報告する。
抽出に失敗した実行は読み終えた位置を進めないので、次の実行が同じ範囲を読み直す。
保存済みの発言は読み直しでもmodelへ渡さない。
確認待ちの`pending`は位置とは別に保たれ、次の実行が`dotfiles-memory status`で確かめる。位置は読んだ範囲であり、確認待ちが残っていても進む。service の終了 status 0 は抽出と確認が失敗しなかったことを表し、保存が確定したことは表さない。
前回の`pending`がstatusで失敗した場合は、logのsourceが指す発言を確かめ、残すなら`memory` Skillで明示的に保存する。

実行の最後の`summary:`の行は、抽出の成否と backend の保存確定を別々に示す。

```text
summary: extraction=succeeded backend-saved=2 backend-unconfirmed=1
```

`backend-saved`は今回の実行で backend が保存を確定した件数、`backend-unconfirmed`は確定を確かめられていない receipt の件数である。全件の保存が完了したと言えるのは`backend-unconfirmed=0`のときだけで、`extraction=succeeded`や終了 status 0 だけではそう言えない。

## 状態

読み終えた位置と確認待ちの receipt は `~/.local/state/dotfiles-wsl/memory-harvest.json` にある。receipt は`pending`を受け取った時点で書くので、実行の途中で取り消しても残る。file を消すと、次の実行は 7 日前から読み直し、確認待ちの receipt を確かめなくなる。

状態は同じdirectoryの一時fileへ書き終えてから置換し、書込失敗では以前の状態を保つ。
強制終了などで残った一時fileは、次に同じ状態fileを書くときに回収する。
writerは親directoryの排他を保持し、この状態fileの一時fileの名前、所有者、通常file、mode 0600が一致するものだけを除去する。
並走中のwriter、別の状態file、旧来の無名の一時fileは巻き込まない。

## 手動で実行する

timer を待たずに実行する。timer の実行中に同じ command を呼ぶと、worker を始めず終了 status 75 で返る。

```sh
dotfiles-agent-memory-harvest
```

project に保存済みの記憶は、checkout の root で一覧できる。

```sh
printf '{"cwd":"%s","scope":"project"}' "$PWD" | dotfiles-memory curated | jq '.memories[] | {kind, source, content}'
```

## 排他と実行の上限

timer と手動の実行は同じ job entry を通り、収穫の writer は一つだけである。1 回の実行は開始から 6 時間までで、期限、取消の signal、worker の突然死のいずれでも、子 process が全て終わってから排他を解く。期限は 124、取消は 128 に signal 番号を足した値で終わり、成功にならない。期限の後は model と memory command を新しく始めない。取消でも、受け取った receipt は state file に残り、次の実行は同じ発言を送り直さない。

## 旧 system timer からの切替

収穫の service と timer は、以前は system manager の`dotfiles-agent-memory-harvest.timer`だった。declaration を適用すると、NixOS の switch は旧 system の timer と service を、user の設定を有効にする前に停止する。旧 service の停止は、旧 worker の全 process が消えるまで終わらない。切替後は次を確認する。

```sh
systemctl is-active dotfiles-agent-memory-harvest.timer dotfiles-agent-memory-harvest.service
systemctl --user is-active dotfiles-agent-memory-harvest.timer
```

1 行目は 2 つとも`inactive`、2 行目は`active`であることを確かめる。state file の読み終えた位置は引き継がれるので、取り逃した範囲は次の実行が読む。

model に渡す情報、判定の梯子、信頼境界は [AI tooling](../architecture/ai-tooling.md#記憶の収穫)を参照する。job の寿命は [AI tooling](../architecture/ai-tooling.md#非対話-job-の寿命)を参照する。
