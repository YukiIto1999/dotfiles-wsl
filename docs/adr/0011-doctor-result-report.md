# 0011. doctor は result core から human / JSON report を生成する

## 状態

Accepted

## 背景

従来の `dotfiles-doctor` は probe の途中で表示し、global counter で終了 status を決めていた。この構造では、人向け表示と機械処理が別の事実を読む。

## 決定

各 probe は表示せず、check result を result core に追加する。check は安定 ID、phase、status、subject、expected、observed、message、`durationMs` を持つ。

report schema v1 は `schemaVersion`、`manifestSchemaVersion`、`outcome`、status 別件数の `summary`、順序付き `checks` からなる。human renderer と JSON renderer は完成した result core だけを読む。`--format json` を指定した場合、stdout には JSON document を1個だけ出す。

result core に `error` があれば status 2、`fail` または `blocked` があれば status 1、それ以外は status 0とする。不正な引数と signal 終了では report を出さない。

## 影響

probe の副作用と表示が分かれ、human 文言を変えても JSON report の構造は変わらない。
