# 作業日誌

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

omp の session 記録から 1 日分の作業と判断を要約し、`agent-journal` repository に機械ごとの Markdown として記録する。1 日は 06:00 から翌日の 06:00 までとし、深夜の作業は前日に入る。

## 前提

hostで`dotfiles.agents.journal.enable = true`を宣言し、OMPを採用した場合だけcommandとuser timerを配備する。
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

`dotfiles-agent-journal.timer` は user manager の timer で、毎日 06:00 に同名の user service を起動する。service は`agents.slice`の中で動き、直前に終わった 1 日から 7 日前までのうち、続きが要る日を記録する。WSL が止まっていて起動を逃した場合は、次に user manager が起動したときに実行する。omp の作業がない日は file を作らない。

```sh
systemctl --user status dotfiles-agent-journal.timer
journalctl --user -u dotfiles-agent-journal.service -n 50
```

失敗した日があると service は非ゼロで終わり、`dotfiles-doctor` の `maintenance/dotfiles-agent-journal.timer` に現れる。この observation は user manager の unit を読むので、`dotfiles-doctor` は日誌を動かす user で、`XDG_RUNTIME_DIR` のある login session から実行する。user manager に届かない場合は、system manager の同名 unit を代わりに読まず、観測の失敗として報告する。

## 日ごとの段

1 日の日誌は、次の 4 つの段のどこまで進んだかを別々に判定する。

| 段 | 状態 | 次の通常の実行 |
|---|---|---|
| 未生成 | file がない | session から model で生成し、commit して push する |
| 生成済み | file はあるが local commit にない | 本文を作り直さず、commit して push する |
| commit 済み | local commit にあるが、`origin`の内容と異なる | push だけを行う |
| 公開済み | `origin`の branch が同じ内容の file を持つ | 何もしない |

公開済みと報告するのは、push の終了 status ではなく、push 後に`origin`の branch から同じ内容を読み戻せた日だけである。commit の hook が失敗した日は生成済みのまま残り、push が失敗した日は commit 済みのまま残る。どちらも総合の台帳を持たず、次の通常の実行が file と Git の状態から未完了の段を判定する。直近 7 日の窓の外にある未完了の file も、この機械の日誌なら同じ段から続ける。1 日の失敗は後の日を止めない。

本文は同じdirectoryの一時fileへ書き終えてから置換するため、途中の本文を日誌として公開しない。
書込や置換の失敗時は自分の一時fileの除去を試み、強制終了などで残った場合は次の実行で回収する。
回収はこの機械の一時fileの名前、所有者、通常file、mode 0600を照合し、実在する日付の実directoryだけを対象にする。
lookbackの外も回収するが、その日の日誌を再生成することはなく、別の機械、symlinkの年や日付directory、旧来の無名の一時fileは対象にしない。
回収できないdirectoryは失敗として報告し、ほかの日の処理は続ける。

```sh
journal=$(nix eval --raw .#nixosConfigurations.<host-id>.config.dotfiles.workstation.environmentDir)/agent-journal
git -C "$journal" status --short
git -C "$journal" log '@{upstream}..HEAD' --oneline
```

`status`に出る`2026/<MMdd>/<機械名>.md`が生成済みの日、`log`に出る commit が commit 済みで未公開の日である。

## 排他と実行の上限

timer と手動の実行は同じ job entry を通り、同じ日誌の writer は一つだけである。timer の実行中に手動で呼ぶと、worker を始めず終了 status 75 で返る。1 回の実行は開始から 6 時間までで、期限、取消の signal、worker の突然死のいずれでも、子 process が全て終わってから排他を解く。期限は 124、取消は 128 に signal 番号を足した値で終わり、成功にならない。

## 旧 system timer からの切替

日誌の service と timer は、以前は system manager の`dotfiles-agent-journal.timer`だった。declaration を適用すると、NixOS の switch は旧 system の timer と service を、user の設定を有効にする前に停止する。旧 service の停止は、旧 worker の全 process が消えるまで終わらない。実行中だった日は途中で打ち切られ、新しい実行が file と Git の状態から続ける。switch の後に次を確認する。

```sh
systemctl is-active dotfiles-agent-journal.timer dotfiles-agent-journal.service
systemctl --user is-active dotfiles-agent-journal.timer
```

1 行目は 2 つとも`inactive`、2 行目は`active`であることを確かめる。旧 timer が記録した起動の履歴は新しい user timer へ引き継がないので、切替当日に起動を逃した日は`dotfiles-agent-journal`を手動で一度呼んで取り戻す。

## 手動で作り直す

特定の日を作り直すときは日付を指定する。内容が変わらなければ commit しない。

```sh
dotfiles-agent-journal --date 2026-09-23
```

日付を指定しない手動の実行は、timer と同じ通常の実行である。途中で止まった日の続きにも使える。

```sh
dotfiles-agent-journal
```

model に渡す情報と信頼境界は [AI tooling](../architecture/ai-tooling.md#作業日誌)を参照する。job の寿命は [AI tooling](../architecture/ai-tooling.md#非対話-job-の寿命)を参照する。
