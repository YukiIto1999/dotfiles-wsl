# ADR 0009: GitHub account の集合と個数を host の宣言だけが持つ

**読み手:** GitHub account を増減する人と、host 固有の事実をどこに置くかを判断する人。

## Status

Accepted

## Context

`identity/module.nix` は account id の集合を module 内の list として持ち、`accounts` option の型を `types.enum` でその要素に限定し、さらに assertion で「宣言された account を漏れなく一度ずつ含むこと」を要求していた。`checks/checks/repository-structure.nix` は 2 件だけを宣言した host を不正な構成として負例に固定していた。

その結果、mechanism が表していた抽象は GitHub account ではなく、特定の 3 件の account だった。1 件でも 2 件でも評価が落ち、4 件目は型が拒否する。account がいくつあるかという host 固有の具象が、汎用の機構の契約に混入していた。

この repository の他の roster は別の形を採る。Skill と Capability は owner module が registry へ自分を寄せ、host は id の pattern 検査だけを通る list で選ぶ。account には寄せる owner がなく、どの account が存在するかは純粋に host の事実である。

候補は三つあった。現状維持、enum の要素を増やす形、型を pattern 検査にして集合と個数を host の宣言だけに置く形である。enum の要素を増やす形は、個数の上限を mechanism に残し、host が account を増やすたびに mechanism を触らせる。同じ問題を先送りするだけである。

primary の決め方も同じ性質の問題を持っていた。`accounts` の先頭を primary とする位置依存の契約であり、`docs/operations/secrets.md` が並べ替えを意味のある操作として記述していた。

## Decision

`accounts` の型を account id の pattern 検査にする。mechanism が検査するのは、非空であること、重複がないこと、id の形が正しいことという形だけとする。どの account が存在し、いくつあるかは `profiles/workstation.nix` の宣言と暗号化済み secret だけが持つ。

primary は位置ではなく `primary` option の明示宣言で決め、宣言した値が `accounts` の要素であることを検査する。

## Consequences

account の増減は host の profile と暗号化済み secret だけで完結し、mechanism は変わらない。`accounts` の並べ替えは挙動を変えない。

負例は、空の roster、重複した id、不正な形の id、`accounts` に含まれない `primary` になる。2 件だけを宣言した host は正当な構成になる。

id の集合を mechanism が知らないため、secret の欠落は評価時ではなく sops の展開時に現れる。roster と暗号化済み key を同じ変更に含める運用規律は引き続き必要である。
