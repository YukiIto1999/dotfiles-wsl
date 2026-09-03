---
name: tdd
description: Implements an understood behavioral change through one observable vertical slice at a time using RED, minimal GREEN, and touched-scope REFACTOR. Use when adding or correcting behavior and a meaningful automated verifier can be run. Proves that each check fails for the intended reason before production changes, then uses concrete cycle feedback to improve responsibility and real extension seams without predesigning abstractions. Does not diagnose unknown failures, choose an overall test strategy, review existing tests, perform a standalone refactor, or validate a throwaway prototype.
---

# TDDで実装する

既に決まったbehaviorを、consumerから観測できる小さな縦のsliceとして実装する。testを先に増やすことではなく、実装前後の証拠を一つのfeedback loopにする。

## Work unitを固定する

repositoryのtest command、既存test、命名、fixture、実装規約を先に読む。次を一文ずつ定める。

- actorまたはconsumer、そのuse case、そのbehaviorを変える理由
- 現在のobservableと、変更後のobservable
- 今回のsliceに含む一つのbehavior
- そのbehaviorを最短で判定できるcommand

意味、契約、期待結果が未決定なら設計へ戻る。異なるactorまたは変更理由のbehaviorを、実装が同居しているという理由で同じsliceに混ぜない。bugの原因が未確定なら`bug-analysis`を先に使う。

分かっているbehaviorをtest listへ置く。listは実装構造を固定する仕様ではない。list全体のtestや実装を先に作らず、外から観測できる最小のsliceを一つ選ぶ。新しいdependency、failure、型が必要なら、consumerが使う最小の契約まで同じsliceに含める。

## REDを証明する

現在のsliceのproduction codeを変える前に、observableを判定するtest、contract check、type check、static checkのいずれかを追加する。性質を判定できる最も内側の決定的なverifierを選ぶ。test levelやfidelityの全体方針が未決定なら、TDDを始める前に別の設計判断として確定する。

testはconsumerが使う安定した契約に置く。private call、現在の分岐順、具体classへの依存を固定して、後の責務移動やcase追加を妨げない。testを書くために無関係なdependencyやsetupが必要なら、test helperで隠す前に責務の混在か隠れた依存を疑う。

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

## GREENから設計feedbackを得る

GREENの後、触れた範囲で何がどの理由により変わったかを確認する。次は構造を見直す具体的な圧であり、自動的な抽象化の指示ではない。

- 一つのactorの一つの判断が複数箇所へ散った
- 一つのownerが、別のactorまたは別の変更理由のためにも変わった
- 新しいcaseの追加が、契約の変わらない既存caseのtestや本文まで書き換えた
- testがprivate interaction、無関係なdependency、広いfixtureを要求した

責務の分割では、処理の段階やclassの大きさでなく、actorと変更理由をownerにする。別の変更理由に属する判断は対応するownerへ移す。呼び出しや分岐を一箇所へ集めただけで、異なる判断を同じownerに残した状態を責務分離とみなさない。新しいcaseでは、既存の直和へ新しいarmを足す、または既存の方針契約へ実装を足す形を先に使い、既存caseのtestと本文を保つ。

一つの具体例からinterfaceやstrategyを作らない。明示されたextension contractがある場合か、複数の具体例から安定部分と変動部分を反証可能な形で確認できた場合だけ、触れた範囲に最小のseamを置く。三つ目の同種要求は有力な観測機会であって、個数だけをgateにしない。classやinterfaceを作ること自体をOCPとみなさない。

observableを変えずに、証拠のある圧だけをGREENのまま解消する。sourceを変えたら影響するfocused checkを実行し、既存behaviorのtestを変更せず保つ。命名、重複、分岐、実装詳細も同じ範囲で整える。

public contract、module owner、system topologyの再設計が要るなら、TDDのREFACTORで決めず、`interface-design`、`module-design`、`code-design`へ戻す。別の目的を持つ広いbehavior-preserving transformationは`refactoring`へ渡す。TDDのREFACTORを理由に変更範囲を広げない。

## 次のsliceへ進む

実装中に判明したbehaviorはtest listへ戻し、現在のGREENへ混ぜない。直前のcycleが明らかにしたdependency、変更理由、設計の圧を使って次のobservableを一つ選び、REDから繰り返す。既存caseの契約が変わらないのに、次のcaseを通すため既存testを弱めたり書き換えたりしない。

完了時は、変更した境界に必要なverificationを狭いものから一度だけ実行する。同じsource、command、環境、inputで成功済みのcheckを繰り返さない。報告には、各sliceのREDが何を理由に失敗し、どのGREENで通ったかを含める。

意味のあるobservableを自動判定できない場合、test専用の浅いseamを足して進んだことにしない。testabilityか設計の不足として示し、境界を決め直す。既に実装済みの変更へ後からtestを足す作業、既存behaviorのcharacterization、test suiteの監査はTDDとして扱わない。
