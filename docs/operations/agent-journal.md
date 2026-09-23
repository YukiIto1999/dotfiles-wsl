# 作業日誌

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

omp の session 記録から 1 日分の作業と判断を要約し、`agent-journal` repository に host ごとの Markdown として記録する。1 日は 06:00 から翌日の 06:00 までとし、深夜の作業は前日に入る。

## 前提

`dotfiles.workstation.environmentDir` の下の `agent-journal` に、日誌の repository を clone しておく。場所は checkout の root で確かめる。

```bash
nix eval --raw .#nixosConfigurations.<host-id>.config.dotfiles.workstation.environmentDir
```

commit は Git の既定 identity で作り、`origin` へ push する。日誌には業務の作業の要約も入るため、`origin` は private repository にする。

## 出力

日誌は `<yyyy>/<MMdd>/<host-id>.md` に書く。冒頭の表は、session 記録から数えた project ごとの session 数、request 数、費用である。project ごとの本文は model が書いた依頼、決定と根拠、変更と検証、未決事項で、各項目には根拠にした session の短い ID が付く。本文の後には、その project の session の完全な ID と、同じ時間帯の commit を並べる。session の記録は `omp --resume <session の ID>` で開ける。

## timer

`dotfiles-agent-journal.timer` は毎日 06:00 に起動し、直前に終わった 1 日から 7 日前までのうち、まだ file のない日を記録する。記録した日は 1 日ごとに commit して push する。model の呼び出しなどで失敗した日は file を作らずに次の日へ進み、次の実行で作り直す。1 回の実行は 6 時間で打ち切る。WSL が止まっていて起動を逃した場合は、次に起動したときに実行する。omp の作業がない日は file を作らない。

```sh
systemctl status dotfiles-agent-journal.timer
journalctl -u dotfiles-agent-journal.service -n 50
```

失敗した日があると service は非ゼロで終わり、`dotfiles-doctor` の `maintenance/dotfiles-agent-journal.timer` に現れる。commit 済みで push できなかった日誌は、次に記録した日と一緒に push する。

## 手動で作り直す

特定の日を作り直すときは日付を指定する。内容が変わらなければ commit しない。

```sh
dotfiles-agent-journal --date 2026-09-23
```

model に渡す情報と信頼境界は [AI tooling](../architecture/ai-tooling.md#作業日誌)を参照する。
