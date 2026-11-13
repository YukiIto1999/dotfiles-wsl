---
name: improve-codebase-architecture
description: Scan a codebase for deepening opportunities, present them as a visual HTML report, then grill through whichever one you pick.
disable-model-invocation: true
---

# codebaseのarchitectureを改善する

architecture上の摩擦を見つけ、shallowなmoduleをdeepにする**deepening候補**を提案する。目的は、testのしやすさと、AIが構造をたどりやすいことである。
利用者が明示して呼んだときだけ使うcommandであり、一般のtaskから自動では起動しない。

## 判断の根拠

module、interface、seam、depthなどの語彙と、統合や分割の可否、seamの位置、依存の性質に応じたtestの組み方は、`codebase-design`の判断に従う。その内容をこのcommandへ写さず、候補を挙げる側も退ける側も同じ基準で判断する。
domainの語は`GLOSSARY.md`から、決定済みの判断は`docs/adr/`のADRから読む。ADRに記録された決定は蒸し返さない。

## 1. 探索する

**探す前に範囲を絞る(YAGNI)。** deepeningは、そのmoduleへの将来の変更を楽にして初めて報われる。最近変わった領域を重く見て、どこを見るかを先に決める。

- 利用者が方向(module、subsystem、困りごと)を示したら、それに従い、下の推定は省く。
- 示さなければ、`git log --oneline`で十分な期間のcommit履歴をさかのぼり、繰り返し現れるfileと領域(hot spot)を見つけ、そこへ注意を向ける。変更が散って明確なhot spotがなければ、範囲を広げる。

先に`GLOSSARY.md`と、触れる領域のADRを読む。
独立して調べられ、委譲の費用に見合う領域があれば、探索をsubagentへ分ける。範囲、用語とADRの要点、下の問いを渡し、fileの場所付きの観測を受け取る。短い調査や分離できない探索は自分で進め、候補の統合と推薦は呼出し側が所有する。
固い手順に頼らず、有機的に探索し、摩擦を感じた箇所を記録する。

- 一つの概念を理解するために、多くの小さなmoduleを行き来しなければならない箇所はどこか。
- interfaceが実装とほぼ同じ複雑さの、**shallow**なmoduleはどこか。
- testのためだけに純粋関数を切り出したが、実際の不具合はその呼び出し方に潜んでいる箇所はどこか(**locality**がない)。
- 密結合のmoduleがseamを越えて漏れている箇所はどこか。
- testがない、または今のinterface越しにはtestしにくい領域はどこか。

shallowを疑うものには`codebase-design`のdeletion testを当て、moduleが隠す決定と呼出側へ露出する複雑さを確認する。

## 2. HTML reportで候補を示す

自己完結したHTML fileをOSのtemp directoryに書き、repositoryには何も置かない。temp directoryは`$TMPDIR`、なければ`/tmp`(Windowsでは`%TEMP%`)を使い、実行ごとに新しいfileになるよう`<tmpdir>/architecture-review-<timestamp>.html`へ書く。利用者のために開き(Linuxは`xdg-open <path>`、macOSは`open <path>`、Windowsは`start <path>`)、絶対pathを伝える。

layoutと装飾は**CDN経由のTailwind**、graph、flow、sequenceが構造を確実に伝える図は**CDN経由のMermaid**を使う。Mermaidと、手組みのCSSやSVGの図を混ぜる。関係がgraph型(call graph、依存、sequence)ならMermaid、編集的な図(mass diagram、cross-section、折り畳みのanimation)が欲しければ手組みのdivやSVGを使う。各候補に**before/afterの図**を付ける。視覚で伝える。

候補ごとに次を持つcardを描く。

- **Files**: 関係するfileとmodule
- **Problem**: 現在のarchitectureが摩擦を生む理由
- **Solution**: 何が変わるかの平易な説明
- **Benefits**: localityとleverage、testがどう良くなるかの言葉での説明
- **Before / After diagram**: 並べて描く手描きの図。shallowさとdeepeningを示す
- **Recommendation strength**: `Strong`、`Worth exploring`、`Speculative`のいずれか。badgeで示す

reportの最後に、どの候補から着手するかと理由を示す**Top recommendation**の節を置く。
統合を含む候補は、統合する対象が同じ決定、権限、状態の寿命を共有する根拠と、既存testの扱いを、Solutionか図の注記で示す。

domainには`GLOSSARY.md`の語、architectureには`codebase-design`の語を使う。`GLOSSARY.md`が「Order」を定義していれば、「FooBarHandler」や「Order service」でなく「Order intake module」と書く。
reportの本文は、利用者が使っている言語で書く。

**ADRとの衝突**: 候補が既存のADRと矛盾するのは、ADRを見直す価値があるほどの摩擦が実在するときだけ表に出す。cardに警告の注記(例: 「contradicts ADR-0007, but worth reopening because…」)で明示する。ADRが禁じる理論上のrefactorを全部並べない。

HTMLの雛形、図の型、装飾の指針は[html-report](references/html-report.md)を読む。

この段階ではinterfaceを提案しない。fileを書いたら、利用者に「どの候補を掘り下げますか」と尋ねる。

## 3. 選ばれた候補をgrillする

利用者が候補を選んだら、`grilling`を使って決定の木をたどる。制約、依存、deepenしたmoduleの形、seamの背後に置くもの、残すtestを扱う。

決定が固まるたびに副作用を即座に反映し、`domain-modeling`でdomain modelを最新に保つ。

- **`GLOSSARY.md`にない概念でdeepenしたmoduleに名を付けるか?** その語を`GLOSSARY.md`へ足す。fileがなければ、その時に作る。
- **会話中にあいまいな語が明確になったか?** その場で`GLOSSARY.md`を更新する。
- **利用者が重要な理由で候補を退けたか?** 「今後のarchitecture reviewが再び提案しないよう、これをADRとして記録しますか」と尋ねる。将来の探索者が同じ提案を避けるために実際に必要な理由だけを対象にし、「今は割に合わない」のような一時的な理由と、自明な理由は省く。
- **deepenしたmoduleの別のinterface案を探索するか?** `codebase-design`を使い、その別interface案を比べる手順(design it twice)に従う。
