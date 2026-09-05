---
name: code-design
description: Designs private implementation structure inside a fixed module and module-level public contract. Use when deciding module-internal types, functions, transformations, algorithms, control or data flow, pure decisions versus effects, resource handling, private abstractions, or a UI module's private component tree and props before implementation. Keeps public behavior and ownership fixed, compares materially different internal structures, and selects the smallest sufficient mechanism. Does not choose module or shared-component ownership, public contracts, domain or persistent-data meaning, internal error placement or propagation, visual appearance, review or edit existing code, perform a behavior-preserving refactor, choose a test strategy, or implement the design.
---

# Module内部の実装構造を決める

成果はclassやhelperの数ではなく、固定済みのcontractを、局所的で追跡可能なdata flowと最小の所有物で実現できる内部構造である。

## 外側の制約を固定する

対象module、owner、module-level public contract、consumer-visible behavior、failure、side effect、ordering、resource lifetimeを確認する。未確定なら内部設計で補わず、該当する`module-design`、`interface-design`、`domain-modeling`、`error-design`へ戻す。dataの意味と正準形が未確定なら、それも内部functionより先に決める。module-privateなcomponent間のpropsは内部構造として設計してよい。

対象code、interface、直接caller、test、dependency、隣接する同種実装、repository規約、必要な履歴を読む。UI moduleでは既存のdesign system、shared primitive、feature-local componentも確認する。観測事実、確定済みの制約、未確認の仮定を分ける。新しいbehaviorやpublic contractを設計へ混ぜない。

## Contractから内部flowを逆算する

代表caseごとに次を一本のflowとして追う。

1. inputをどこから受け取るか
2. どこでparse、normalize、validateするか
3. どの判断と変換を行うか
4. どのeffectをどの順序で実行するか
5. successか確定済みfailureへどう写すか
6. 固定済みerror policyのまま、failureとcancel時のresource解放をどこで保証するか

値の出所、変形、所有者を途中で見失うflowは分割する。処理順の説明をlayerやclass名へ置き換えない。

## 内部表現を一つにする

未検証入力を受けるtrust boundaryをmoduleが所有する場合は、入口で一度だけparseし、内部を一つのcanonical formへ収束させる。既に検証済みの値を受け取るなら再検証しない。

言語が支える範囲でillegal private stateを表現不能にする。booleanやnullの組み合わせで状態を暗示せず、実在するvariantを区別する。ただし、domain、data、failureに新しい意味を発明しない。単位、時刻、識別子、absenceの意味は外側のcontractから受け取る。

## 判断とeffectを必要な分だけ分ける

policyとI/Oの両方があり、分離によって理解、再現、変更の局所性が改善する場合は、read、decide、writeに分ける。純粋な判断は明示した入力だけを受け、effectの実行方法やambient stateを読まない。

小さいadapter、直線的なCRUD、言語やframeworkが既にresource lifecycleを閉じる処理へ、pure core、port、DI、wrapperを強制しない。effect分離自体を成果にしない。

## UI moduleでは既存componentから始める

確定済みのfeatureとobservable stateについて、実際のrender tree、design system、shared primitive、隣接するfeature-local componentを先に確認する。まず一つのfeature-local treeを直接案にし、同じ理由で変わるrender、interaction、state、effectを、file sizeや技術種別だけで分割しない。

既存primitiveは今回の意味とinteractionに適合する場合だけ再利用する。薄いpass-through、見た目の類似、将来のreuseを理由に新しいcomponentを抽出しない。feature-local componentをshared ownerへ移す判断は`module-design`、外部公開するcomponent contractは`interface-design`へ渡す。visual、layout、motionはUI設計へ渡す。

## 最小の十分なmechanismを選ぶ

次の順で足りるか確認する。

1. 既存の型、helper、patternをそのまま使う
2. 言語、標準library、frameworkのnative mechanismを使う
3. 導入済みdependencyの正規mechanismを使う
4. module内へ直接実装する
5. 必要な知識だけを新しいprivate abstractionへ置く

新しいabstractionは、同じ知識を持ち同じ理由で変わる複数箇所、実在する変化、知識の局所化、具体的な変更や検証costの低下のいずれかで費用を回収する場合だけ残す。共通語、対称性、短い呼出し元、将来の可能性だけでは作らない。独立oracleの意図的な重複をDRYで消さない。

既存abstractionも無条件に使わない。それを外したとき、隠していた知識やinvariantがcallerへ漏れるか、変更と検証costが増えるかを確認する。何も失わずindirectionだけが消えるなら、今回の設計をそのabstractionへ拡張しない。

code、shell、query、configを文字列として生成する汎用rendererは、escaping、validation、出力順を一箇所で正しく所有し、直接表現より誤用を減らす場合だけ作る。閉じた定数の対応を別形式へ移すだけのhelperは追加せず、repositoryの既存literalかnative builderを使う。

## 実質的な案だけ比較する

新しいabstractionを作らない直接案を対照に置く。別案は、内部表現、algorithm、effect配置、知識のownerのいずれかが変わる場合だけ作る。

exact interfaceとhard constraintに反する案を先に落とす。残る案は、change amplification、cognitive load、data locality、unknown dependency、project idiom、testability、mechanism costで比較する。点数を合算せず、同じ制約下で支配する案か、今回のriskに対するtrade-offを選ぶ。

## 設計を閉じる

一案を推薦し、次だけを必要に応じて返す。

- privateなtype、function、data flowの関係
- 該当する場合はcomponent責務、state owner、props、event、slotの関係
- 判断とeffectの境界、resource lifecycle
- 保持するinvariantとfixed interfaceへの写像
- 採らなかった案と具体的な費用
- 後続の実装とTDDが確認するproperty

pseudocodeは関係を明確にする場合だけ使う。production code、test、ADR、実装計画を作らない。既存構造を変更する仕事は`refactoring-implementation`、確定済みbehaviorの実装は`tdd-implementation`へ渡す。
