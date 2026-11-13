# 依存を持つmodule群を深くする

shallowなmodule群を統合するか、seamを残したまま深くするかを決め、その後のtestの組み方を選ぶ。
[SKILL.md](../SKILL.md)の語彙と、seamを置く三つの入力(責務と隠す決定、権限、状態の寿命)を前提にする。

## 統合の条件を決める

統合は、候補が同じ決定を隠し、同じ権限の下にあり、同じ寿命の状態を扱う場合に限る。
一つでも違えば、その違いが切り替わる位置のseamは内側に残し、呼出し側へ見えるinterfaceだけを小さくする。
同じprocessにあることも、現在のadapterが一つであることも、統合や分離の理由にしない。

## 依存の性質からtestを決める

依存の性質は、seamを越えるtestの組み方を決める。seamを置くかどうかは、上の三つの入力で先に決まる。

| 性質 | 例 | testの組み方 |
|---|---|---|
| in-process | 純粋な計算、I/Oのないin-memoryの状態 | 同じ決定、権限、寿命を共有するものを統合し、新しいinterfaceから直接testする。adapterは要らない。権限や寿命が異なる状態を含む部分は内側のseamに残す |
| local-substitutable | 局所で動く代替がある(PGLiteとPostgres、in-memoryのfilesystem) | 代替をtest suiteで動かす。seamは内側に置き、moduleの外側のinterfaceへportを出さない。代替と実物の差が契約に及ぶ項目は別に確かめる |
| 自分が所有するremote | 自分のmicroservice、内部API | seamにportを置き、論理を深いmoduleが持ち、transportをadapterとして渡す。testはin-memoryのadapter、本番はHTTP、gRPC、queueのadapterを使い、両者が同じ契約のtestを通る |
| 外部の第三者 | 決済、SMSなど制御できないservice | 外部の依存をportとして受け取り、testにはmockのadapterを使う。mockが返す応答と失敗の形が実serviceの契約に一致する根拠(公開された契約、sandboxでの確認)を残す |

networkをまたいで配備されても論理を一つのdeepなmoduleに置くため、本番用とtest用のadapterをportへ差し込む形を推薦する。

## seamの根拠を確かめる

portを置く根拠は、そのseamで切り替わるものを名指せることである。adapterの数では決めない。

- 実装が本番の一つだけでも、外部service、永続化、credential、別の主体が決める事柄を越えるseamは実在する。testの実行条件と観測する契約から、実dependencyと代替物の役割を決める。
- 隠す決定が実際に異なる二つ目の実装は、seamが実在する証拠になる。
- 実物でtestできる依存へ、testのためだけにportと代替を作るのは、間接層を足すだけである。
- 同じ決定を隠すだけで権限も寿命も変わらない二つ目のadapterは、portの根拠にならない。
- 実装が一つで、何も切り替わらず、testにも代替が要らないportは置かない。

内部のseamはimplementationの内側に置き、そのmoduleのtestだけが使う。testが使うからといって、interfaceへ出さない。

## 既存のtestを扱う

統合しても、interfaceはtestの面である。新しいinterfaceで、観測できる結果を主張するtestを書く。
既存のtestは、検証している契約ごとに分ける。

- 新しいinterface越しに同じ契約を確認でき、同じ観測を重ねるだけのtestは、新しいtestが同じ契約を覆ったと確かめてから置き換える。
- interface越しには再現しにくい契約(境界値、失敗の注入、順序や並行実行、永続化と復旧)を検証するtestは残す。seamに置いたadapterで失敗を注入し、interface越しの観測へ移してもよい。どちらでも、その契約の検証を失わない。
- 契約を検証せず、内部の転送や呼出回数だけを固定するtestは削除する。失われるbehaviorの検証があれば、その契約をinterface越しの観測へ移してから置き換える。

testがinterface越しの観測で保てないなら、moduleの形か、interfaceへ出す観測できる結果を見直す。
代替物を使うtestは、実際のdependencyの契約を検証したことにならない。[SKILL.md](../SKILL.md)の検証の節に従って、実adapterの契約の確認を残す。
