# ADR 0007: 機械構成の実現機構に Nix と Home Manager を単一採用する

**読み手:** この repository の構成をどの機構で実現するかを判断する人。

## Status

Accepted

## Context

標準の `tools/` は rust、csharp、typescript の言語 ecosystem と、build、platforms、services の区分を定める。宣言的な機械構成をどの機構で実現するかについては定めを持たない。標準は、明示的な定めを持たない目的については project 自身が決定し、単一採用として記録することを求め、沈黙を一般的な手法による補完の暗黙の許可と解釈してはならないと定める（標準 `README.md` の「標準の単一性と例外の管理」）。

候補は三つあった。手続き的な shell script で構成を適用する形、構成管理ツールで到達状態を記述する形、Nix flake と NixOS と Home Manager で構成を宣言する形である。

一つ目は適用の順序と冪等性を実装ごとに持ち、適用前の状態に依存する。二つ目は到達状態を記述できるが、適用結果の同一性を成果物の identity として持たないため、別の host で同じ結果になることを機構として保証しない。

三つ目は、`flake.lock` が全 input を固定して評価を再現可能にし、generation の切り替えと巻き戻しを機構として持ち、配備物を store path として同一性で識別する。この identity は配備物の drift 検査の根拠になっており（`managed-artifacts/module.nix`）、検証入口も `nix flake check` の一つに閉じる（`flake.nix`）。別の host へ clone して同じ構成を再現する目的に対して、この三つが揃うのは三つ目だけである。

## Decision

機械構成の実現機構として Nix flake、NixOS、Home Manager を単一採用する。同じ目的に対して別の構成管理機構を併置しない。

## Consequences

構成の正本は Nix 宣言と、それが参照する asset および暗号化済み secret になる。生成先を直接編集しても正本は変わらず、次の activation で上書きされる。

配備物の同一性が store path として決まるため、drift 検査と managed artifact の登録がその identity を根拠にできる。検証は `nix flake check` の一つの入口に集まる。

標準の `tools/` が将来この目的を扱った場合は、標準の migration の手順に従って照合する。
