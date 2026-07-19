# 0001. 関連ファイルの隣接配置と単一宣言

## 状態

Accepted

## 背景

旧構造は `home/` / `templates/` / `modules/` にファイルが分散していた。MCP server を 1 つ足すには
template、pkgs、module の 3 箇所を編集する必要があり、変更漏れが実際に発生した(監査で確認済み)。
CLI・account も同様に複数箇所へ手で登録する構造だった。

## 決定

ファイルは主に参照する module の近くに置く。MCP server は `pkgs/<name>` + `modules/mcp/servers/<name>.nix`、
CLI は `modules/clis/<name>/` にまとめる。MCP server・CLI・account はそれぞれ 1 箇所の
list/import にのみ登場し、複数箇所への転記を要求しない(`modules/mcp/default.nix` の imports、
`modules/clis/default.nix` の imports、`flake.nix` の `my.accounts`)。

JSON、TOML、YAML の不変設定は、配備を所有する module が実値を使って一度だけ生成する。
同じ source を NixOS、Home Manager、SOPS template、OCI volume、doctor の該当 consumer へ渡し、
`my.configArtifacts` には構文検査用の `source` と `format` だけを公開する。配備先、mode、secret
展開、user seed、doctor 対象の意味論は各 module に残し、中央 registry から自動生成しない。

## 検討した代替案

種別別ディレクトリへの集約(`templates/` に全 template を置く案)。一覧しやすくなるが、1 サーバー追加が
`templates/` / `pkgs/` / `modules/` の 3 箇所編集を要求し、同じ変更漏れを起こすため不採用。

設定の配備方法まで中央 registry に集約する案。immutable な `/etc`、Home Manager symlink、
CLI が所有する user seed、activation 時に秘密値を展開する SOPS template では変更責任と検証方法が
異なる。flag と例外を増やして責務を隠すため不採用。

## 影響

追加・削除は隣接ファイルの変更で完結し、変更漏れの原因が減る。全 MCP server の一覧は
`modules/mcp/default.nix` の imports で確認する。`config-syntax` は dummy 値から別の設定を再生成せず、
各 module が実配備へ渡す artifact を検査する。
