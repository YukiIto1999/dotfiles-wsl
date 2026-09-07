# ADR 0004: root の境界を関心の owner ごとの unit とする

**読み手:** root 直下に何を置くか、新しい関心をどこへ足すかを判断する人。

## Status

Accepted

## Context

標準の `structure/skeleton.md` は、対象 project の root 構成を `core`、`libs`、`contracts`、`surfaces`、`runtimes`、`deploy`、`tests` として定め、実行時とビルドのコード境界と、それらの間の依存方向を規定する。この repository は systemd service、timer、CLI command を所有するが、それらは各 unit の宣言から NixOS generation が構成する出力であり、core から build する application code ではない。業務の core、外部との contract 層、polyglot workspace に対応する関心を持たないため、この骨格に対応づけられない。

標準は、明示的な定めを持たない目的については principles の要求と禁止事項に照らして project 自身が決定し、単一採用として記録することを求め、標準の沈黙を一般的な手法による補完の暗黙の許可と解釈してはならないと定める（標準 `README.md` の「標準の単一性と例外の管理」）。

候補は三つあった。skeleton の骨格をそのまま写す形、技術カテゴリで分ける形、関心の owner を unit とする形である。一つ目は対応する関心のない空の箱を作る。二つ目は、処理の段階、技術層、ファイル種別だけを理由に境界を決めることを禁じる規律に当たる（標準 `principles/separation/split-by-change-reason.md`）。

## Decision

root 直下の境界は、変更を要求するアクターと変更理由が一致する関心の owner を単位とする。新しい関心も同じ単位で足す。

## Consequences

同じ分類の問いに答える兄弟要素が root に並び、`flake.nix` の unit 収集が `module.nix` の存在を marker にする形と一致する。

標準の `structure/skeleton.md` とは対応しないため、標準が改訂されて宣言的な機械構成に対する骨格が定義された場合は、標準の migration の手順に従って照合する。

unit の内部 layout と、採用している言語と実現機構は、それぞれ別の判断として扱う。
