---
name: commit-writing
description: Writes a commit message from the staged diff and repository policy. Use when asked for a commit message or immediately before committing staged changes. Identifies one purpose and one revert reason, records why the change exists rather than listing files, and never changes the index. Does not write PR bodies, changelogs, or release notes.
---

# Commit messageを書く

## 手順

1. repository rootの`AGENTS.md`、`CONTRIBUTING.md`、commit hookを確認する。形式、言語、type、scope、長さ、bodyの可否はlocal policyを優先する。
2. `git diff --staged`を読む。staged diffが空ならmessageを作らない。
3. 変更が解消する問題か、成立させる目的を一文にする。変更したfileや操作を主語にしない。
4. diff全体が同じ目的と同じrevert理由を持つか確認する。複数ならindexを変更せず、分けるべき目的とpathを報告する。
5. typeを差分ではなく目的に合わせて選ぶ。`test`や`docs`は、それ自体が変更目的の場合だけ使う。
6. repository policyがbodyを許す場合でも、subjectだけで直接の目的が分かるようにする。構造判断の文脈、代替案、帰結はADRへ置く。
7. 日本語なら`ja-writing`を併用する。

## 出力

repositoryが要求するcommit messageだけを出す。候補を複数並べない。確定できない場合はmessageを作らず、足りない事実を示す。

## 禁止事項

- staged stateを変更する。
- 「更新する」「修正する」「整理する」だけで目的を隠す。
- file名や変更操作の列挙をWhyの代わりにする。
- 実行していない検証や、確認していないissueをmessageへ入れる。
- repository policyが禁じるscope、body、trailer、AI attributionを足す。
