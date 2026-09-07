# ADR 0002: 標準本文を版を固定した flake input として参照する

**読み手:** 標準本文の参照方法と、その版が更新される条件を確かめる人。

## Status

Accepted

## Context

標準は「プロジェクトは標準の版を固定せず、配備されている現在の標準本文を基準にします」と定め、過去の版を基準にすると改訂済みの規律への適合を合格と誤判定すると述べる（標準 `README.md` の「標準リポジトリの参照方法」）。

一方この repository は、外部依存を flake input として宣言し、`flake.lock` で固定して評価を再現可能にする。標準本文は plugin Skill の source として評価入力に入り、agent へ配備される Skill 本文の一部になる（`flake.nix` の `architectureStandard` input と `skills/plugins/module.nix`）。flake は input を lock する機構であるため、評価入力である限り版は固定される。固定を避けるには標準本文を評価入力から外し、実行時に checkout を読む経路へ移す必要がある。その経路は、配備物の drift 検査が store path の一致を根拠にする現在の仕組みと両立しない（`managed-artifacts/module.nix`）。

候補は三つあった。標準本文を評価入力から外して実行時に読む形、input を宣言しつつ rev を書かず lock だけに任せる形、rev を明示して固定する形である。一つ目は drift 検査の根拠を失う。二つ目は lock により版が固定される点は変わらず、固定の所在が `flake.nix` から `flake.lock` へ移って更新の意図が履歴から読めなくなる。

## Decision

標準本文は `flake.nix` の `architectureStandard` input として rev を明示して参照する。標準の「版を固定しない」規律からの逸脱として、この記録を単一の採用とする。撤回条件は、標準本文を評価入力から外しても配備物の drift 検査の根拠を保てる経路が成立したときである。

## Consequences

標準の改訂は input の更新として commit に現れ、どの時点の標準を基準にしたかを履歴から辿れる。一方、input を更新しない限り判断の基準は固定した版に留まるため、基準の遅れを検出する責任は input を更新する運用の側にある。
