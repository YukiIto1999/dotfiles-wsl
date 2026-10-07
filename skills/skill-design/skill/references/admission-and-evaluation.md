# Admission and evaluation

## Mechanism gate

| Mechanism | 選ぶ条件 |
|---|---|
| nothing | baselineが十分で、反復する能力差がない |
| policy | ほぼ全taskで常時必要な短い規則 |
| reference | 必要時に知ればよく、独立した手順を持たない知識 |
| script / tool | 正解を決定的に抽出、検証、変換できる処理、または外部能力へのaccess |
| existing Skill | 既存のJobと判断所有権に自然に含まれる不足 |
| signature procedure | 分解や一般化で価値が失われる固有の手順 |
| custom Skill | 反復する文脈依存の不足に、独立した方法、routing、判断所有権がある |

独自の判断や推敲の方法は、toolを使わなくてもSkillの候補になる。
toolの利用を定める場合は、いつ、何の証拠のために使い、結果をどう評価するかまで所有し、呼び出し一回だけを独立したJobにしない。

## Admission gate

次の一つでも説明できなければdraftへ進まない。

- Skillなしで観測した具体的なdeficit
- 反復するcoherentなJob
- 既存Skillと重ならない判断所有権
- realisticなtriggerとnear-miss
- baselineと異なる方法
- policy、reference、script、toolよりSkillが適切な理由
- context、routing、保守、評価costに見合う期待uplift

## Scenario contract

baselineとforward evalは、分類表のcellではなく実taskから作る。単一repository shapeや直近の例だけに合わせない。

- typical: Jobを必要とする代表task
- variant: input、repository、model、制約のいずれかが異なる同種task
- boundary: 前提が欠ける、または作業を止めるべきtask
- near-miss: 語彙は似るが隣接Skillか基礎モデルが所有するtask
- composition: 一緒に使う可能性が高いSkillがあるtask

promptへSkill名や本文の語彙を埋めて発火と成果を誘導しない。評価criterionは方法の復唱でなく、正しいoutcomeと不要な行動の不在を測る。

各scenarioには、与える入力と制約、根拠の取得先、期待する成果、その条件で必要な委譲と返却結果、不要な操作を対応させる。
compositionを含む場合は、Skill名の出現ではなく、入力と証拠の受け渡し、返却結果による継続、判断所有権の重複がないことを確かめる。
方法だけで完了するscenarioでは、成果の質を測り、toolや他Skillを使わないことを不足としない。
作業経路のscenarioでは、実際の公開schemaで操作と入力を照合し、取得結果の評価と次の判断まで追う。
利用できないSkillやCapabilityがあるscenarioでは、偽の返却結果を作らず、独立した成果と不足証拠を分けて止めるかを確かめる。
この対応はcandidateの実taskに合わせ、全Skillへ同じworkflowや成果物templateを強制しない。

## 比較観点

- capability: 正確さ、判断、成果がbaselineより改善したか
- routing: typicalで発火し、near-missを奪わないか
- process: 必要なevidence、検証、停止条件を扱ったか
- restraint: 不要なfile、抽象、質問、tool call、調査、説明を増やさないか
- composition: 重複作業、競合命令、隠れたworkflowを生まないか
- stability: 文面、repository shape、modelが多少変わっても有効か

自動judgeとeval harnessも検査対象である。fixture、timeout、trigger検出、rubric、baseline、information leakageの不良をSkillの効果と混同しない。

## Split、merge、ablation

trigger、判断所有権、evidence、単独利用が異なる場合はsplitを検討する。常に同時発火し、同じ判断を持ち、一方がforwardingだけならmergeする。名前や分類の対称性を理由に分けない。

節、reference、script、Skillの順に削除して同じscenarioを再評価する。品質が変わらない要素は戻さない。Skill全体を外しても差がなければ、既存Skillへの統合か削除を選ぶ。
