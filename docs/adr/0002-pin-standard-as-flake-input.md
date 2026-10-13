# ADR 0002: 標準の配備版を固定した flake input とし、規範本文は現行 checkout から読む

**読み手:** 標準本文の参照方法と、配備する実行 package の版が更新される条件を確かめる人。

## Status

Accepted

## Context

標準は「プロジェクトは標準の版を固定せず、現行規範 root にある現在の標準本文を基準にします」と定め、過去の版を基準にすると改訂済みの規律への適合を合格と誤判定すると述べる（標準 `README.md` の「標準リポジトリの参照方法」）。

一方この repository は、外部依存を flake input として宣言し、`flake.lock` で固定して評価を再現可能にする。
標準は plugin Skill の source として評価入力に入り、agent へ配備される Skill、checker、設定の実体になる（`flake.nix` の `architectureStandard` input と `skills/plugins/module.nix`）。
flake は input を lock する機構であるため、評価入力である限り版は固定される。
配備物の drift 検査は store path の一致を根拠にするため、実行 package の固定は外せない（`managed-artifacts/module.nix`）。

しかし drift 検査と実行の再現性が要求する同一性は、Skill、checker、設定という手順の同一性であり、規範本文の現行性ではない。
固定した input の写しを規範本文の基準にすると、配備版が現行規範の正本に見え、`dotfiles-doctor` の drift の PASS が現行の標準への適合と読まれる。
標準が定める参照方法は、標準を管理する owner が現在の規範として指定した checkout の root を agent に渡して一次資料を直接読ませることであり、Skill の配備先や固定した store の写しから推定することではない。

候補は四つあった。
標準を評価入力から外して実行時に読む形、rev を明示して固定し規範本文もその写しから読む形、rev を明示して固定する input を実行 package に限り規範本文を現行 checkout から読む形、rev を書かず lock だけで実行 package を固定し規範本文を現行 checkout から読む形である。
一つ目は Skill と checker も評価入力から外れ、drift 検査の根拠を失う。
二つ目は版の遅れた写しが現行規範の基準になり、改訂済みの規律への適合を合格と誤判定する。
三つ目は規範本文を写しから読まなくても、`flake.nix` の URL に書いた rev が配備版を現行規範の基準に見せ、固定の所在が URL と lock に分かれる。
四つ目は固定の所在が `flake.lock` だけになり、更新の意図は lock を更新する commit にだけ現れる。
lock は実行 package の出典であり規範の基準ではないため、この所在で足りる。

## Decision

標準は `flake.nix` の `architectureStandard` input として宣言し、rev は URL に書かず、`flake.lock` が実行 package の出典として固定する。
運用 Skill、checker、設定は、この lock が指す不変の実行 package として配備する。
現行規範は、`dotfiles.workstation.environmentDir` の下の architecture-standard にある owner 指定の canonical checkout の現在の本文である。
その root を `dotfiles.agents.runtime.standardRoot` に公開し、全 client の policy と `dotfiles-agent-gate standard-root` が同じ値を案内する。
規範文書の参照と適合の判断はこの root から行い、同梱の reference と script は成功して読んだ Skill の実体の directory から解決する。
固定した input の store 上の写し、URL、Git revision、`flake.lock`、`dotfiles-doctor` の drift の PASS は、供給物の出典と同一性を示すだけで、現行規範の根拠にしない。
root または必要な file を読めない場合は不足を返し、固定版の写しや記憶で補わない。
規範本文の基準を版に固定しないため、標準の「版を固定しない」規律からの逸脱は残らない。
実行 package の固定は、配備物の drift 検査が実行 package の同一性を根拠にしなくなったときに見直す。

## Consequences

規範本文の改訂は、owner が受け入れて canonical checkout へ統合した時点から次の読取りの基準になり、input の更新を待たない。
input の更新は `flake.lock` を更新する commit として現れ、どの版の Skill と checker を配備したかを履歴から辿れるが、その版は現行規範の基準ではない。
更新後の規範本文を配備済みの実行 package が扱えない場合は配送不足として失敗し、旧本文や旧 package で合格にしない。
具体的な store の gate を埋め込んだ hook で開始した session は、その gate と成功して読んだ実行 package のまま動き、更新後の package は新しい session へ届く。
この配備より前に始まり `/run/current-system` を参照する hook は、呼出しごとに現在の generation の gate へ解決されるため、保持の対象にならない。
