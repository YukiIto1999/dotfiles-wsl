# ADR 0008: unit の内部 layout を役割の軸で固定する

**読み手:** unit の直下に何を置けるかを判断する人。

## Status

Accepted

## Context

root 直下の境界は関心の owner ごとの unit とする（[ADR 0004](0004-adopt-owner-unit-root-structure.md)）。その unit の内部に何を置けるかは別の判断であり、標準は個別の定めを持たない。

候補は三つあった。unit ごとに自由な構成を許す形、役割の軸で固定する形、技術層で分ける形である。

一つ目は、同じ意味の要素が unit ごとに別の名前と階層へ散る。標準は「同じ architecture level を表す tree 間で、分類軸と概念の対応を追跡できる」ことを完了条件に置くため（標準 `principles/separation/classification-granularity.md`）、この形は満たせない。三つ目は、処理の段階や技術層だけを理由に境界を決めることを禁じる規律に当たる（標準 `principles/separation/split-by-change-reason.md`）。

## Decision

unit の直下に置けるのは、宣言の `module.nix`、build の `package.nix`、検証の `checks.nix` と `checks/`、固定値の `fixtures/`、実現の `impl/`、資材の `assets/`、unit の責務で説明できる固有資材、および子 unit を持つ directory だけとする。

この許可集合の正本は `checks/checks/repository-structure.nix` の `structure-layer-names` であり、集合外の entry は build で落ちる。

## Consequences

役割を増やす判断は許可集合の変更として現れ、取り残した entry は検査が落とす。

unit 固有の資材名を増やすほど分類軸は緩むため、追加はその unit の責務から説明できる場合に限る。
