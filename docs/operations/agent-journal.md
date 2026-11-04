# journal の運用

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

OMP の原 session から技術的な知見や気づきを抽出し、`agent-journal` repository に機械ごとの Markdown として記録する。
活動報告や業務仕様の集積ではなく、人が知見の根拠と適用条件を理解できる記事を作る。
採用する内容、出典、品質と失敗の契約は [journal の仕様](../architecture/agent-journal.md)を正本とする。
収集する 1 日は 06:00 から翌日の 06:00 までとする。

## 前提

hostで`dotfiles.agents.journal.enable = true`を宣言し、OMPを採用した場合だけcommandとuser timerを配備する。
既定では無効であり、新しいPCへ自動pushを引き継がない。

有効にする前に、`dotfiles.workstation.environmentDir`の下の`agent-journal`へ、journal の repository を clone しておく。
場所はcheckoutのrootで確かめる。

```bash
nix eval --raw .#nixosConfigurations.<host-id>.config.dotfiles.workstation.environmentDir
```

commit は Git の既定 identity で作り、`origin` へ push する。
出典の引用には非公開プロジェクトの記録も入るため、`origin` は private repository にする。

## 出力

日誌は `<yyyy>/<MMdd>/<機械名>.md` に書く。
機械名は `dotfiles.agents.journal.machineName` の宣言値で、既定値は host ID である。
既存の日誌の file 名を引き継ぐ host は、[`profiles/hosts/`](../../profiles/hosts) の host profile で機械名を宣言する。
`nixos` は既存の日誌に合わせて Windows のコンピューター名 `y-itoh` を宣言している。
機械名は Windows の interop から実行時に取得しないので、interop が応答しなくても日誌は止まらない。
file 名に使えない文字を含む機械名は、評価の時点で option の型が拒否する。

本文はプロジェクト別の作業一覧ではなく、技術的なテーマごとの記事である。
各記事には、発見、その説明と適用条件、注意点、根拠の引用と完全な session ID・entry ID を付ける。
費用、request 数、全 commit と session の一覧は出力しない。
元の会話は `omp --resume <session の ID>` で開き、記事の entry ID から根拠の原文を確認できる。
原記録に entry ID がなければ、明記された行番号で確認する。
活動があっても知見がなければ、その旨を記した文書を作る。

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

新しい形式の marker を持たない未公開の旧記録は、そのまま commit または push せず、その日の失敗として報告する。
先に日付を指定してプレビューを読み、原 session から明示的に作り直す。
公開済みの旧記録も知見へ変換済みとは扱わず、通常実行での一括上書きや削除は行わない。
未公開の旧記録がすでに commit されている場合は、その branch の後続の日も公開できない。
Git の push は未公開 commit の列をまとめて送るため、記録の機械名によらず旧形式を検査する。
後続の日の生成と local commit は続けても、旧記録を明示的に再生成するまでは push を拒否する。

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

## 内容を確認して作り直す

日付を指定したプレビューは、通常と同じ生成と引用検査を行い、完成した Markdown を標準出力へ返す。
journal の repository へアクセスせず、同期、file の書込み、commit、push を行わない。

```sh
dotfiles-agent-journal --preview --date 2026-09-23
```

知見が具体的か、根拠と適用条件を理解できるか、報告と仮説を混同していないかを読む。
生成や引用検査が失敗すると非ゼロで終わり、途中の記事は標準出力へ返さない。
プレビューには `--date` が必要である。

内容を確認した日だけを作り直すときは、プレビューを外して同じ日付を指定する。
この実行は既存の本文を置き換え、Git hook を通して commit と `origin` への push まで行う。
内容が変わらなければ commit しない。

```sh
dotfiles-agent-journal --date 2026-09-23
```

日付を指定しない手動の実行は、timer と同じ通常の実行である。途中で止まった日の続きにも使える。

```sh
dotfiles-agent-journal
```

model へ渡す情報と送信の限界は [journal の仕様](../architecture/agent-journal.md#入力と日付の境界)、隔離と認証は [AI tooling](../architecture/ai-tooling.md#技術的な知見の集積)を参照する。
job の寿命は [AI tooling](../architecture/ai-tooling.md#非対話-job-の寿命)を参照する。
