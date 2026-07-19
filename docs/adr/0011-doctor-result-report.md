# 0011. doctor は result core から human / JSON report を生成する

## 状態

Accepted

## 背景

従来の `dotfiles-doctor` は probe の途中で `OK`、`WARN`、`FAIL` を直接表示し、global counter で終了 status を決めていた。この構造では、人向け表示と機械処理が別の事実を読む。rebuild が文章を解析すれば表示変更が transaction の成功判定を壊し、終了 status だけを読めば失敗した check を receipt に残せない。

manifest の破損、runtime の不収束、依存元の失敗による未実行も区別できなかった。current generation が成立しない状態で高コストな probe を続けると、異なる世代や user identity の外部状態を診断結果へ混ぜる。

## 決定

各 probe は表示せず、一つ以上の check result を result core に追加する。check は次を持つ。

- 安定 ID
- `foundation`、`local`、`system`、`active` の phase
- `pass`、`warn`、`fail`、`error`、`blocked` の status
- subject、expected、observed、message、`durationMs`

`foundation` は manifest、configured user / home、current generation、system profile、実行中 doctor、cold-start state を扱う。ここで `fail` または `error` が出た場合、残りの phase は probe を呼ばず `blocked` result にする。`local` は immutable source との比較と PATH 配備、`system` は systemd と root metadata、`active` は CLI、Windows、MCP の bounded probe を扱う。active probe は共有する `HOME` や session を持つため、manifest 順に逐次実行する。

report schema v1 は `schemaVersion`、`manifestSchemaVersion`、`outcome`、status 別件数の `summary`、順序付き `checks` からなる。check ID は report 内で一意、summary は checks から再計算した値と完全一致しなければならない。human renderer と JSON renderer は完成した result core だけを読む。有効な引数で `--format json` を指定した場合、stdout には JSON document を1個だけ出す。

result core を生成した場合、終了 status と outcome を次の対応にする。不正な引数は result core を生成しない。

| status | outcome | result |
|---:|---|---|
| `0` | `healthy` | `pass` と `warn` だけ |
| `1` | `degraded` | `fail` または `blocked` があり、`error` はない |
| `2` | `invalid` | 有効な形式で起動後、manifest または result core の contract error |
| `2` | report なし | 引数が不正で、result core を生成する前に終了した |
| `130` / `143` | report なし | INT / TERM を受け、所有する session の cleanup を試行した |

rebuild は forward target と schema v3 の rollback target について、closure 内の doctor を `--format json` で1回だけ実行する。doctor の raw status を成功判定の正本にしつつ、JSON document 数、report と manifest の schema、全 check field、ID 一意性、summary 再計算、status / outcome の対応を検証する。検証できない report は `doctor.report` の contract failure とし、doctor が0を返していても status 2へ正規化する。検証できた `fail` / `error` の ID は receipt schema v2 の `verification.failedCheckIds` に保存する。

schema v3 を導入する最初の世代では、recovery target が schema v2 の旧 generation になり得る。rollback target の manifest が schema v2 だと確認できた場合だけ、rebuild は旧 doctor を引数なしで1回実行する。旧 doctor の human 出力を保持したうえで、status 0を `healthy`、status 1を `degraded` とする report v1へ変換し、`legacy.doctor` check と manifest schema 2を明示して同じ validator に通す。それ以外の status は変換せず `doctor.report` とする。この互換経路は forward target、schema v3、schema が不明な target には広げない。schema v2 の generation を recovery target として扱わなくなった時点で削除する。

## 影響

probe の副作用と表示を分離できる。human 文言を変更しても rebuild の判定は変わらず、rebuild は report の outcome だけで doctor の raw status を上書きしない。失敗した transaction は store path と check ID を同じ receipt に残すため、resume は同じ candidate の再検証から再開できる。

report は観測結果であり、宣言状態の新しい正本ではない。期待値は ADR 0010 の manifest v3 だけに置く。report を checkout に保存したり、次回 doctor の入力として再利用したりしない。
