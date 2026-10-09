# ADR 0007: 機械構成の実現機構に Nix と Home Manager を単一採用する

**読み手:** この repository の構成をどの機構で実現するかを判断する人。

## Status

Accepted

## Context

標準の `tools/` は rust、csharp、typescript の言語 ecosystem と、build、platforms、services の区分を定める。宣言的な機械構成をどの機構で実現するかについては定めを持たない。標準は、明示的な定めを持たない目的については project 自身が決定し、単一採用として記録することを求め、沈黙を一般的な手法による補完の暗黙の許可と解釈してはならないと定める（標準 `README.md` の「標準の単一性と例外の管理」）。

候補は三つあった。手続き的な shell script で構成を適用する形、構成管理ツールで到達状態を記述する形、Nix flake と NixOS と Home Manager で構成を宣言する形である。

一つ目は適用の順序と冪等性を実装ごとに持ち、適用前の状態に依存する。二つ目は到達状態を記述できるが、適用結果の同一性を成果物の identity として持たないため、別の host で同じ結果になることを機構として保証しない。

Nixは`flake.lock`のinput固定、generationの切り替えと巻き戻し、store pathによる配備物の同一性を持つ。
このidentityは`managed-artifacts/module.nix`のdrift検査の根拠になる。
検査の依存もNixで定義され、`flake.nix`は各unitの`checks.nix`と、全hostおよび既存variantのtoplevelを収集する。
別hostへの構成再現と、その構成を検査した成果物の同一性を同じ機構で扱う目的から、Nixを採用する。

標準の`tools/build/nx.md`は「task の定義と実行の正本は、Nx に一本化する」と定める。
本repositoryの検証taskにもこの規律を照合するが、NixOS moduleの評価、derivationの依存、hostのsystem closureを別のtask graphへ重ねないため、検証の定義と実行もNixを正本とするproject固有の判断を採る。
これは標準がNixをtask orchestratorとして採用しているという判断ではない。
技術的な前提は、検査対象と実現物が現在のNix graphから導かれ、Git sourceとstore pathの対応を検証入口が維持できることである。

## Decision

機械構成の実現機構としてNix flake、NixOS、Home Managerを単一採用する。
検証taskの正本はrootの`flake.nix`と各unitの`checks.nix`に置き、三段のNix appから実行する。
別のrecipe、task graph、cache、影響範囲selectorで同じ検証定義を再保持しない。
共有resolverとclientのgateは、この正本への接続と成功証跡の判定だけを担当する。
他projectへの接続形式を、このrepositoryのtask定義として採用しない。

登録hostとNixOS fixtureは、rootで構成した共通のNixpkgs package setをupstreamのread-only moduleから受け取る。
hostとfixture側での`nixpkgs.config`、`nixpkgs.overlays`、`nixpkgs.pkgs`、host/build platformの上書きは、`lib.mkForce`を含めて禁止する。
package構成とplatformの変更も、共通ownerであるrootの`flake.nix`へ集約する。

## Consequences

構成の正本は Nix 宣言と、それが参照する asset および暗号化済み secret になる。生成先を直接編集しても正本は変わらず、次の activation で上書きされる。

配備物の同一性がstore pathで決まるため、drift検査とmanaged artifactの登録はそのidentityを根拠にできる。
T1は全unitの検査と全hostおよび既存variantの評価、T2は検査とsystem closureの実現、T3は全量flake checkとして、同じ宣言から導く。
NixのGit sourceへ入らない未追跡fileは検証前に追跡し、検証後にsourceが変われば終了gateの証跡を失効させる。
Nixのcache hitだけでは終了を受理せず、宣言した入口を既存wrapperで通した同じsourceの証跡を要求する。

標準の機械構成に関する採用が定まった場合、またはNix graphで必要な保証と実行予算を維持できなくなった場合は、この単一採用と`tools/build/nx.md`への対応を再評価する。
その場合も、必要な検査を後の段へ移したり、二つの検証正本を恒久的に併置したりしない。
