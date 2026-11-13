---
name: codebase-design
description: Designs and reviews module structure with a shared deep-module vocabulary (module, interface, depth, seam, adapter, leverage, locality). Use when deciding what a module owns and hides, where an interface or seam goes, whether to merge shallow modules or split one, which way dependencies should point, how to test through an interface, or when another Skill needs this vocabulary. Places seams by responsibility, hidden decisions, authority, and state lifetime, not by process or adapter count. Does not map existing dependencies, estimate the impact of one change, choose visual UI design, or diagnose failures.
---

# moduleのinterfaceとseamを設計する

成果は、各moduleが担う責務と隠す決定、seamの位置、そのinterface越しに検証できるbehaviorである。
小さなinterfaceの後ろに多くのbehaviorを置き、利用者にはleverage、保守者にはlocality、検証にはinterface越しの観測しやすさを与える。

## 語彙

次の用語は言い換えずに使う。「component」「service」「API」と揺らして書かない。

- **module**: interfaceとimplementationを持つもの全般。関数、class、package、複数のtierにまたがるsliceなど、規模を問わない。
- **interface**: 利用者が正しく使うために知るべきことのすべて。型シグネチャに加え、不変条件、順序の制約、失敗の形、必要な設定、性能特性を含む。
- **implementation**: moduleの内側にある本体。
- **depth**: interfaceにおけるleverage。学ぶinterfaceの単位あたりに、利用者やtestが引き出せるbehaviorの量。多くのbehaviorが小さなinterfaceの後ろにあれば**deep**、interfaceが実装とほぼ同じ複雑さなら**shallow**である。
- **seam**: そこを編集せずに振る舞いを変えられる場所であり、moduleのinterfaceが置かれる位置。どこに置くかは、その背後に何を置くかとは別の設計判断である。
- **adapter**: seamでinterfaceを満たす具体物。中身の大小でなく、どの位置を埋めるかという役割を指す。小さなadapterが大きな実装を持つこと(Postgresのrepository)も、大きなadapterが小さな実装を持つこと(in-memoryのfake)もある。seamが話題のときだけadapterと呼び、それ以外はimplementationと呼ぶ。
- **leverage**: depthが利用者にもたらすもの。同じinterfaceを学ぶだけで、一つの実装がN箇所の呼出しとM個のtestに効く。
- **locality**: depthが保守者にもたらすもの。変更、不具合、知識、検証が呼出し側へ散らず、一か所に集まる。

使い分けも守る。
interfaceを型や公開methodだけの意味にしない。
英語のboundaryをseamやinterfaceの言い換えに使わない。bounded contextと混ざる。
depthを、実装の行数とinterfaceの行数の比で測らない。実装を水増しするほど深く見えるためである。
projectに`GLOSSARY.md`があれば、domainの概念はその語で呼び、architectureの語はこの語彙で呼ぶ。

## seamの位置を決める

seamは、責務と隠す決定、権限、状態の寿命のいずれかが切り替わる位置に置く。その切替えを名指せない位置には置かない。

- **責務と隠す決定**: 各moduleが担う責務と、呼出し側へ漏らさず決めている事柄を書き出す。変更理由が異なる決定を同じinterfaceの背後へ混ぜず、同じ決定を複数のmoduleへ散らさない。片方を変えるともう片方も直す組は、同じ決定を共有している。
- **権限**: 事実、状態、判断を最終的に決める主体を一つにする。credentialや外部serviceのように、別の主体が決める事柄も含む。同じ事実を複数のmoduleが決められると、不変条件はどのinterfaceでも守れない。決める側のinterfaceに集め、他は結果を読む。
- **状態の寿命**: 状態ごとに、所有者、寿命(呼出し、request、session、process、永続)、共有の範囲、失敗や再起動の後の扱いを決める。所有者や寿命が違う状態を一つの実装へ混ぜず、同じ所有者と寿命の状態を呼出し側へ散らさない。

同じprocessに載っているか、adapterがいくつあるかは、この判断を決めない。

- 同じprocessでも、権限や寿命が違えば別のseamになる。例は、正本と、そこから導いて捨てられるcacheである。
- 実装が一つでも、権限や寿命が切り替わる位置のseamは実在する。例は、外部serviceと永続化である。
- 二つ目の実装は、隠す決定が実際に切り替わる証拠になる。実物でtestできる依存へ、testのためだけに代替を作って増やしたseamは、間接層を足すだけである。
- 何も切り替わらないseamは置かない。

依存の向きは、利用する側が、決定を隠して提供するmoduleのinterfaceへ向かう形にする。提供する側が個々の利用者の事情を知ると、隠したはずの決定が呼出し側に依存する。

## moduleを深くする

見直す対象のmoduleごとに、責務と隠す決定を挙げる。
同じ決定を共有し、権限と寿命も同じなら、統合してdeepにする候補である。
呼出し側が毎回同じ順に組み合わせ、その組合せの知識を持っているなら、知識をinterfaceの背後へ移す。
depthはinterfaceの性質であり、implementationの性質ではない。deepなmoduleの内側が、小さく交換できる部品でできていてもよい。その内側のseamはmoduleのinterfaceへ出さない。

次で確かめる。

- **deletion test**: moduleを消したと想像する。複雑さが消えるなら、通過させているだけだった。複雑さがN箇所の呼出し側へ現れるなら、役目を果たしている。
- methodの数を減らせるか、引数を単純にできるか、より多くの複雑さを内側へ隠せるか。
- 呼出し側が内部の順序や状態を知らないと正しく使えない箇所は、interfaceへ漏れている。

依存を持つmodule群を統合する手順と、依存の性質に応じたtestの組み方は[deepening](references/deepening.md)を読む。

## interface越しに検証する

interfaceはtestの面でもあり、呼出し側とtestは同じseamを通る。
interfaceを越えて内部を調べないと検証できないなら、moduleの形が悪いか、観測すべき結果がinterfaceへ出ていない。
testは内部状態でなく、interface越しに観測できる結果を主張し、内部の組換えでは書き換えずに済む形にする。実装を変えるたびに直すtestは、interfaceを越えて検証している。

検証しやすい形にするため、次を使う。

- seamを越える依存は、moduleの中で作らず受け取る。
- 副作用で変えるより、結果を返す。
- interfaceの表面を小さくする。methodが少なければtestも減り、引数が少なければ準備も単純になる。

依存を代替物(fake、mock、in-memoryのadapter)に替えたtestは、moduleが想定する契約に対する振る舞いを検証する。
実際のdependencyがその契約を満たすかは別の検証であり、代替物でtestが通ったことでは確かめられない。
実adapterと代替物が同じ契約のtestを通るか、実dependencyに対する統合確認を持つ。どちらもなければ、代替物の背後の契約は未検証として結果へ残す。

## 他の仕事との境目

既にある依存関係の事実を地図にする仕事は`dependency-analysis`、一つの変更が及ぼす影響の追跡は`impact-analysis`、故障や性能regressionの診断は`diagnosing-bugs`が担当する。
画面の情報設計やvisual designは`ui-design`が担当し、componentの構造やstate ownerのmodule設計だけをこのSkillが担う。
このSkillは設計の判断だけを持つ。上の仕事は利用者が依頼し、対応するSkillが利用可能な場合だけ引き渡し、戻った事実を設計の入力にして、観測と設計の判断を分ける。
使えない場合も設計は完了させ、未実施の仕事と引き継げる証拠を返す。

別のinterface案を比べるときは[design-it-twice](references/design-it-twice.md)を読む。

## 返す結果

- 対象のmoduleと、それぞれが担う責務、隠す決定
- 事実と判断の権限、状態ごとの所有者と寿命
- seamの位置と、そこで切り替わるもの
- interface(型、不変条件、順序、失敗の形、必要な設定、性能特性)
- seamを越える依存の扱いと、実際のdependencyの契約をどこで検証するか
- interface越しに検証するbehavior。既存のtestがあれば、置き換えるものと残すもの
- 採らなかった案とその理由

決められない問いは、不足する入力と共に返す。
