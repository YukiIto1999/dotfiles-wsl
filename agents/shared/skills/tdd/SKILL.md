---
name: tdd
description: Implements an understood behavioral change through one observable vertical slice at a time using RED, minimal GREEN, and touched-scope REFACTOR. Use when adding or correcting behavior and a meaningful automated verifier can be run. Proves that each check fails for the intended reason before production changes and that the exact slice passes afterward. Does not diagnose unknown failures, choose an overall test strategy, review existing tests, perform a standalone refactor, or validate a throwaway prototype.
---

# TDDで実装する

既に決まったbehaviorを、consumerから観測できる小さな縦のsliceとして実装する。testを先に増やすことではなく、実装前後の証拠を一つのfeedback loopにする。

## Work unitを固定する

repositoryのtest command、既存test、命名、fixture、実装規約を先に読む。次を一文ずつ定める。

- actorまたはconsumerと、そのuse case
- 現在のobservableと、変更後のobservable
- 今回のsliceに含む一つのbehavior
- そのbehaviorを最短で判定できるcommand

意味、契約、期待結果が未決定なら設計へ戻る。bugの原因が未確定なら`bug-analysis`を先に使う。

分かっているbehaviorをtest listへ置く。list全体のtestや実装を先に作らず、外から観測できる最小のsliceを一つ選ぶ。新しいdependency、failure、型が必要なら、consumerが使う最小の契約まで同じsliceに含める。

## REDを証明する

現在のsliceのproduction codeを変える前に、observableを判定するtest、contract check、type check、static checkのいずれかを追加する。性質を判定できる最も内側の決定的なverifierを選ぶ。test levelやfidelityの全体方針は`test-design`に渡す。

focused commandを実行し、次を確認する。

- 対象のtestまたはcheckが実際に実行された
- 未実装または誤ったbehaviorを理由に失敗した
- syntax、fixture、環境、無関係な既存failureが原因ではない
- oracleがproduction codeと同じ計算を複製していない

新しい型を接続する場合、既存実装やcallerとの不整合によるtype errorはREDにできる。未定義の型を単独で置いただけのerrorはbehaviorのREDにしない。typeを最小限接続した後、runtime behaviorがあるならそのtestもREDにする。

追加したtestが直ちにpassした場合は、behaviorが既に存在するか、testが変化を観測できていない。理由を確定するまでGREENへ進まない。

## 最小のGREENを作る

現在のsliceを通すproduction changeだけを実装する。test listの後続項目、一般化、将来のextension、別のcleanupを先取りしない。

REDで使ったfocused commandを実行し、同じ対象がpassしたことを確認する。testの削除、skip、期待値の弱化、production behaviorのtest側への複製でGREENにしない。

## GREENのまま整える

現在のsliceで触れた範囲に、重複、曖昧な命名、不要な分岐、露出した実装詳細が残る場合だけ整える。observableは変えず、sourceを変えたら影響するfocused checkを実行する。

別の目的を持つ構造変更や広いbehavior-preserving transformationは`refactoring`へ渡す。TDDのREFACTORを理由に変更範囲を広げない。

## 次のsliceへ進む

実装中に判明したbehaviorはtest listへ戻し、現在のGREENへ混ぜない。次のobservableを一つ選び、REDから繰り返す。

完了時は、変更した境界に必要なverificationを狭いものから一度だけ実行する。同じsource、command、環境、inputで成功済みのcheckを繰り返さない。報告には、各sliceのREDが何を理由に失敗し、どのGREENで通ったかを含める。

意味のあるobservableを自動判定できない場合、test専用の浅いseamを足して進んだことにしない。testabilityか設計の不足として示し、境界を決め直す。既に実装済みの変更へ後からtestを足す作業、既存behaviorのcharacterization、test suiteの監査はTDDとして扱わない。
