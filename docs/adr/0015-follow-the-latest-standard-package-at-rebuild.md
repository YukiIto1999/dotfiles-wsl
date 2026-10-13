# ADR 0015: 標準の実行 package を rebuild のたびに最新へ追従させる

**読み手:** 標準の運用 Skill、checker、設定が配備される版の決まり方と、その更新の経路を確かめる人。

## Status

Accepted

## Context

標準は版を固定せず、現行規範 root にある現在の標準本文を基準にする（標準 `README.md` の「標準リポジトリの参照方法」）。
[ADR 0002](0002-pin-standard-as-flake-input.md) は規範本文を現行 checkout から読むと定めたが、運用 Skill、checker、設定の実行 package は `flake.lock` が指す版で配備し、その更新を人が `nix flake update` で行う運用に任せた。

この運用では、標準を改訂して統合しても、人が lock を更新するまで旧い Skill と checker が配備され続ける。
実測では、`flake.lock` が指す標準の版 `9b58f32` は、canonical checkout の `cf52530` より 5 commit 遅れていた（2026-10-13 に確認）。
遅れた checker は、改訂前の規律で合否を判定する。
標準も、この repository も、他の project も常に改善されるため、固定した版で止まる状態を既定にできない。

候補は四つあった。
人が lock を更新する現状を維持する案、timer が lock を更新して無人で switch する案、評価のたびに最新を取り lock へ記録しない案、`dotfiles-rebuild` が build の前に lock を更新して commit する案である。
一つ目は更新されない状態が既定になり、[ADR 0011](0011-update-omp-from-managed-releases.md) が OMP について退けた理由と同じである。
二つ目は repository の無人の書き換えと generation の無人の切替、passwordless sudo を要し、これも ADR 0011 が退けた理由と同じである。
三つ目は generation が配備した package の版を履歴から辿れず、drift 検査の根拠である store path が評価のたびに変わる。
四つ目は人が実行する rebuild に更新を載せるため、無人の switch を要さず、lock の更新が commit として残る。

## Decision

`dotfiles-rebuild` は、rollback を除く build の前に `nix flake update architectureStandard` を実行する。
更新する input は `architectureStandard` だけであり、他の input は更新しない。
lock が変わった場合は、`flake.lock` だけを `fix: 標準の実行 package の最新版への更新` として commit してから build する。
`--plan` は更新した lock で candidate を build して差分を示し、終了時に `flake.lock` を HEAD へ戻す。
`--rollback` は新しい flake を build しないため、更新しない。

更新を取得できない場合は、警告を出して lock の版のまま続ける。
オフラインでも修復の rebuild を通すためであり、この場合の package は直近に取得できた版である。
更新の commit を作れない場合は、`flake.lock` を HEAD へ戻し、終了 status 2 で switch の前に止める。

`flake.lock` は、各 generation がどの版の実行 package を配備したかの記録として残る。
ADR 0002 の、規範本文を現行 checkout から読む決定は変えない。

## Consequences

配備される実行 package は、直近に成功した `dotfiles-rebuild` の時点の標準の最新である。
前回の更新以降の Skill と checker の差分は、更新のたびにまとめて取り込まれる。

rebuild を実行しない間は更新されない。
無人更新を採らないための限界であり、標準を統合した作業が同じ作業の中で `dotfiles-rebuild` まで実行して補う（`environment-design` Skill）。

lock の更新は人の承認を待たず、main の commit として積まれる。
push は別に利用者へ確認する。

最新の package が更新後の標準本文を扱えない場合は、ADR 0002 のとおり配送不足として失敗し、旧い版の合格で代用しない。
`dotfiles-rebuild --rollback` で前の generation へ戻せるが、次の通常の rebuild は再び最新を取り込むため、原因は標準側または package 側で直す。
