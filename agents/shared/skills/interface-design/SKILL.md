---
name: interface-design
description: Designs an exact consumer-visible contract after the boundary and owner are fixed. Use when defining or changing module exports, Nix options, public library APIs, service operations, commands, events, or messages across a module or process boundary, including inputs, results, failures, side effects, ordering, idempotency, compatibility, and versioning. Does not inventory impact without designing a contract; choose module ownership or seams; define domain meaning or authorization policy; design internal helpers, database schemas, UI component props, state ownership, composition, or reuse, or internal error placement, propagation, or translation; review an existing interface without a design request; implement the contract; or perform its migration.
---

# 境界のcontractを具体化する

成果はfieldやmethodの数ではなく、consumerがproviderの内部を推測せず、成功、失敗、変更を正しく扱える最小のcontractである。

## 境界と正本を固定する

次を先に確認する。

- contract owner、consumer、粗いcapability、domain上の意味
- 現在のcontract、生成経路、binding、既存の正本
- consumerが実際に使う値とobservable behavior
- boundaryのtransport、trust、ownership、serialization
- compatibilityを必要とするreader、writer、配備世代

ownerやseamが未確定なら`module-design`、概念の意味、caller category、authorization policyが未確定ならownerかdomain判断へ戻す。既存contractを変える場合、consumerと影響が未確認なら`impact-analysis`で事実を作る。

既存の正本と同じ意味を持つ別option、field、schemaを作らない。別名で一致をassertするのでなく、既存contractを直接使う。providerのdirectory layout、内部型、vendor errorを公開せず、consumerが必要とする意味へ射影する。ただし、安定した既存contractで十分なら薄いwrapperを追加しない。

## Representative usageから約束を導く

callerが行う代表的な操作を、成功だけでなく次の該当caseまで具体化する。

- 対象なし、空集合、未指定、明示的な削除
- invalid input、競合、部分成功
- cancel、timeout、retry、重複request
- 並行実行、順序、resource lifetime
- collectionの上限、安定順序、continuation、終端

各usageについて、contractだけを見たconsumerが何を送れ、何を受け取り、次に何を判断できる必要があるかを書く。内部実装を知る場合だけ成立するusageはcontract不足として扱う。

## Semantic contractを決める

該当する項目だけを決める。

- 確定済みのoperationかcapabilityの目的、caller category、authorization preconditionとdeniedの表現
- required、optional、default、nullable、単位、範囲、相関制約
- success value、variant、absence、emptyの違い
- side effect、atomicity、idempotency、ordering、concurrency
- expected failureの判別子と、consumerの判断に必要なfield
- cancellation、transport failure、provider defectの扱い
- timeout、resource ownership、lifetime
- compatibilityとdeprecationの前提

expected failureは、consumerが分岐できるsemanticなvariantとして表す。内部exception、stack、SQL、SDK、vendor errorをそのまま漏らさない。system内部でerrorをどこに置き、どう伝播、翻訳、集約するかは`error-design`へ渡す。

## Shapeを必要な場合だけ比較する

shapeによって誤用、caller burden、隠せる判断、surface、互換性が変わる場合だけ複数案を比べる。field名だけを変えた案や、同じ意味を別wrapperにした案を水増ししない。

hard constraintを満たす案の中で、代表usage、illegal stateの表現可能性、consumerの分岐、変更伝播、round tripを比較して一案を選ぶ。点数を合算しない。

## Repositoryのbindingへ射影する

semantic contractをrepositoryが既に使うNix option、言語型、IDL、HTTP、event schemaへ写す。別のcontract DSL、folder、code generatorを、今回必要というだけで導入しない。

bindingでは、名前、型、required/optional/default/null、variant、error、単位をexactにする。semanticな違いをtransportのstatusやnullable一つへ潰さず、binding固有の都合から新しいdomain上の意味を作らない。

生成物が必要な場合だけ、一つの正本からtype、client、docsへ投影し、正本とのdriftを検査する。正本と同じ意味の手書き複製を互換層として残さない。

## Compatibilityを方向付きで判定する

requestではcallerをwriter、providerをreaderとする。responseとeventではproviderをwriter、consumerをreaderとする。各方向で次の組み合わせを調べ、どの配備順と共存状態を許すかを明示する。

- old writerからnew reader
- new writerからold reader

wire bindingではwire compatibilityを判定する。各bindingとconsumerについて、該当するsource compatibility、binary compatibility、evaluation compatibility、observable behaviorを別に判定する。Nixのevaluation compatibilityはNix bindingの場合だけ扱う。必要なconsumer事実は`impact-analysis`で確認し、一つのcompatibilityという語へ潰さない。

変更の一般則は次のとおりである。

- providerが受け入れる入力を広げる変更は、旧callerに対して互換である
- required inputの追加と入力制約の強化は破壊的である
- providerが返す保証を狭く強くする変更は、旧consumerに対して互換である
- null、failure、unionやenumのvariant追加は、exhaustive consumerを壊し得る
- response field追加は、未知fieldを許すreaderに限って互換である
- default、order、idempotency、error categoryの変更は、field追加と別に判定する

この一般則を根拠にreaderとwriterの片方向だけを省略しない。非互換contractを同時運用する必要がある場合だけversionを分ける。packageやreleaseのversionを、上流が定義していないAPI contract versionとして発明しない。共存、切替、旧contract除去はmigrationかrolloutへ渡す。

## 設計を閉じる

代表usageがcontractだけで書け、expected failureを判別でき、variantとabsenceがround tripし、bindingがsemantic contractへ対応することを確認する。example、schema、type、compatibility matrixで後続が検査すべきpropertyを渡し、実装、test、migrationへ進まない。

結果は推薦、exact contractまたは追加不要の判断、compatibility、verification obligationを直接返す。判断に必要な場合だけ代表usage、failure、side effectを添える。文書形式を指定されていなければ、ADR、仕様書、定型tableに包まない。
