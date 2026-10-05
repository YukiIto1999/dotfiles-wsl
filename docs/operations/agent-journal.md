# 作業日誌

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

omp の session 記録から 1 日分の作業と判断を要約し、`agent-journal` repository に機械ごとの Markdown として記録する。1 日は 06:00 から翌日の 06:00 までとし、深夜の作業は前日に入る。

## 前提

hostで`dotfiles.agents.journal.enable = true`を宣言し、OMPを採用した場合だけcommandとtimerを配備する。
既定では無効であり、新しいPCへ自動pushを引き継がない。

有効にする前に、`dotfiles.workstation.environmentDir`の下の`agent-journal`へ、日誌のrepositoryをcloneしておく。
場所はcheckoutのrootで確かめる。

```bash
nix eval --raw .#nixosConfigurations.<host-id>.config.dotfiles.workstation.environmentDir
```

commit は Git の既定 identity で作り、`origin` へ push する。日誌には業務の作業の要約も入るため、`origin` は private repository にする。

## 出力

日誌は `<yyyy>/<MMdd>/<機械名>.md` に書く。
機械名は `dotfiles.agents.journal.machineName` の宣言値で、既定値は host ID である。
既存の日誌の file 名を引き継ぐ host は、[`profiles/hosts/`](../../profiles/hosts) の host profile で機械名を宣言する。
`nixos` は既存の日誌に合わせて Windows のコンピューター名 `y-itoh` を宣言している。
機械名は Windows の interop から実行時に取得しないので、interop が応答しなくても日誌は止まらない。
file 名に使えない文字を含む機械名は、評価の時点で option の型が拒否する。

冒頭の表は、session 記録から数えた project ごとの session 数、request 数、費用である。project ごとの本文は model が書いた依頼、決定と根拠、変更と検証、未決事項で、各項目には根拠にした session の短い ID が付く。本文の後には、その project の session の完全な ID と、同じ時間帯の commit を並べる。session の記録は `omp --resume <session の ID>` で開ける。

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
