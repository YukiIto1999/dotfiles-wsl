# 0003. local skill のシンボリックリンク配備

## 状態

Accepted

## 背景

`share/skills/*`(local skill)の編集に rebuild が必要になると、skill の整備と確認に時間がかかる。
plugin skill は flake input 由来の store path で、編集対象ではない。

## 決定

local skill は home-manager の `home.file` の `source` を
`config.lib.file.mkOutOfStoreSymlink "${cfg.dotfilesDir}/share/skills/<name>"` にし、
リポジトリの作業ツリーへ直接シンボリックリンクする。plugin skill は `mkOutOfStoreSymlink` を使わず、
そのまま plugin の store path へシンボリックリンクする(`modules/clis/default.nix` の `allSkills` 分岐)。

## 検討した代替案

全 skill を store copy として配備する案。SKILL.md の編集がすべて rebuild が必要になり、
「繰り返し作業は skill として整備する」という運用方針と相性が悪いため不採用。

## 影響

SKILL.md 本文の編集は rebuild なしで全 CLI へ反映される。一方、skill 名の列挙は
`builtins.readDir` の結果を flake 評価時に固定する。skill ディレクトリの新設・削除・名前変更は
rebuild 後に反映される。
