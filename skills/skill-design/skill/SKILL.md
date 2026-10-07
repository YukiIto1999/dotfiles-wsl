---
name: skill-design
description: Use when creating or revising an agent Skill, turning a recurring correction into a reusable workflow, auditing Skill overlap or effectiveness, or tuning descriptions that miss real requests or steal adjacent tasks. Decides whether a Skill is needed, then improves its contract through fixed criteria, fresh execution, and one-theme iterations. Can conclude no Skill, merge, or retire. Not for merely using or installing a Skill, ordinary domain work, generic model benchmarking, or automatic evaluation after every edit.
---

# Skillを実行結果から設計する

成果はSkillの追加ではなく、反復する不足を最小の方法で解消した状態である。
契約を固定し、新しい実行者の成果と振り返りから一つの原因を直す。
作らない、統合する、削除する判断も成果になる。

## 0. 契約とIteration 0を固定する

依頼された変更、評価の許可、変更禁止範囲を確定し、現行のsource、policy、隣接Skill、reference、toolの契約を読む。
配備済みcopyを編集対象にしない。
反復した失敗のtask、成果への影響、実行記録のlocatorを集め、観測と推測を分ける。
利用者が報告した失敗は観測として扱い、確認のために同じ失敗を再実行しない。
新しい比較が必要なら、後述の固定したscenarioで測る。

agentの方法でなく標準、基盤、upstream、対象projectの規範が不足している場合は、`environment-design`へ主張、source locator、現行本文との差、許可範囲を渡す。
所有者と入口を受け取り、agentの方法として残る部分だけへ戻る。
入口が使えなければ所有者を推測せず、未確定の部分を返す。

次の順で最小のmechanismを比較する。

| Mechanism | 選ぶ条件 |
|---|---|
| 何も追加しない | 既存の能力で足り、反復する不足が観測されていない |
| policy | ほぼ全taskで常時必要な短い規則である |
| reference | 必要時に知れば足り、独立した判断手順を持たない |
| script / tool | 決定的な処理、または外部能力へのaccessが不足している |
| 既存Skill | 同じJobと判断所有権の中に不足を置ける |
| 固有のprocedure | 分解すると価値を失う方法を、その契約と配備条件ごと採用できる |
| 独立したSkill | 反復する文脈依存の不足に、独立した方法と自然なtriggerがある |

Skillを選ぶには、観測した不足、反復するJob、既存ownerとの差、Skill以外では足りない理由、評価と保守の負担に見合う改善仮説を説明できる必要がある。
想像上の不足、分類表の空欄、一原則、一回のprimitive操作から新しいSkillを作らない。
評価待ちのdraftと、改善を実測した採用判断を区別する。

候補のJob、trigger、判断所有権、必要なevidence、完了するoutcome、non-goals、既存の能力と異なる方法を短く固定する。
同じ判断を常に一緒に行う候補は統合し、trigger、evidence、単独利用の価値が異なる場合だけ分ける。
方法だけで完了するJobには不要な検索や委譲を足さない。
委譲が必要なJobには、発火条件、渡す入力と証拠、返却結果、その結果を使って再開する地点を定める。
`requiresSkills`と`requiresCapabilities`は全scenarioで必要な依存だけに使い、条件付きの枝で配備を止めない。

Iteration 0では、descriptionの各triggerとnon-goalを、本文の入力、手順、停止条件、成果へ対応付ける。
本文に実行経路のない約束は、依頼の契約に従って本文を直すかdescriptionを狭める。
descriptionは利用者の意図と主要triggerを先頭に置き、一つの枝を同義語で繰り返さず、隣接ownerとの重要な境界を示す。
ここでの整合確認は静的確認であり、発火や成果の改善を測ったことにはならない。

## 1. Scenarioと判定を先に固定する

実taskから代表例と境界例を含む2〜3種類の開発scenarioを選び、語彙は似るが別ownerの仕事であるnear-missを加える。
実際に組み合わせるSkillがあればcomposition、必要な能力が欠ける枝があれば利用不能のscenarioを含める。
調整に使わないholdoutを先に分け、同じ能力を要する別の入力や表現を用意する。
C#、Rust、TypeScriptを対象にするJobなら、一言語のrepository shapeだけで一般化を主張しない。

各scenarioに入力、制約、許可する副作用、証拠の取得先、期待する成果を定め、3〜7項目の判定文を固定する。
少なくとも一つを`[critical]`にし、完全達成、部分達成、不達成を何の証拠で区別するかを書く。
判定は方法の復唱でなく、outcome、必要なevidence、不要な操作の不在を測る。
compositionではSkill名の出現でなく、入力と証拠の受け渡し、返却結果による継続、判断の重複がないことを測る。

自然発火のscenarioは候補の名前、本文、使うべきSkill名を依頼へ埋めず、通常の利用者の言い方にする。
taskに本来ある受入条件は両側へ同じ形で渡し、期待解答、発火ラベル、採点専用のrubricは実行者から隠す。
実行結果を見て判定文、critical、holdout、反復回数を変えない。
fixtureかjudgeを直す必要があれば評価版を分け、比較する両側をその版で測り直す。

## 2. 新しい実行者へ渡す

評価を始めるときは[実行契約](references/fresh-execution.md)を読み、現在公開されたAPIとschema、実行mode、取得できる証拠を確定する。
毎回新しい実行者を使い、作者の会話、前回の出力、修正案、失敗台帳を渡さない。
同じagentの再開、作者の自己再読、構造reviewを新しい実行の代わりにしない。

| Mode | 測れること | 測れないこと |
|---|---|---|
| structural | descriptionと本文の整合、実行経路の欠落 | 実行成功、自然発火、改善量 |
| method-only | 本文を明示して使う方法の成果、candidate-freeな本文なし対照との差 | Skill discovery、実tool、環境内のcomposition |
| full-environment | 自然発火、実toolの入力と返却結果、実環境での成果とcomposition | 条件を揃えて候補を除けない場合のno-skill改善量 |

新設ではno-skill対照、改訂では現行版を対照にし、不要性を判断するときはSkill全体を外した対照も使う。
model、thinking、task、policy、tool、repositoryの初期状態を揃え、候補の有無か一つの変更だけを差にする。
異なるmodelへのfallbackや初期状態の差があれば、同条件の比較から外す。

OMPのdispatchはtop-levelが所有する。
subagentとしてこのSkillを使う場合は、実行用briefと判定契約を親へ返し、親がfresh scenarioを起動して結果を評価する。
再帰的なnative subagent起動や、起動不能を迂回する子からの別CLI実行は行わない。
新しい会話であっても、候補のmetadata、preload、policy、共有fileが残る環境を隔離済みbaselineと呼ばない。
必要な対照を作れなければ「baseline未測定」とし、可能なmodeの結果だけを返す。

## 3. 成果と振り返りを別々に判定する

実行者には成果物と証拠のlocatorに加えて、次の短い振り返りを求める。

- Understandingでは、依頼と指示の対象を理解できたかを`OK / stuck / skipped`で返す。
- Planningでは、方針と順序を決められたかを同じ形式で返す。
- Executionでは、実際の作業を完了できたかを同じ形式で返す。
- Formattingでは、要求された成果物の形にできたかを同じ形式で返す。
- 不明瞭点ごとに、観測した`Issue`、指示側の原因仮説である`Cause`、同種の失敗を防ぐ`General Fix Rule`、最初に詰まったphaseを返す。
- 指示で決まらず裁量で補った箇所と、同じ判断をやり直した回数と理由を返す。

全phaseが問題なければ`Trace: all OK`にまとめてよい。
内部の思考過程ではなく、外から確認できる選択、停止、tool結果、成果の不足を報告させる。

評価側は自己採点を転記せず、成果物と実行記録を固定した判定文へ照合する。
判定可能な各項目を完全達成`1`、部分達成`0.5`、不達成`0`で採点し、達成率を`100 × 合計 / 項目数`で示す。
全criticalが完全達成の場合だけ成功とし、一つでも部分達成か不達成なら失敗にする。
証拠がなく判定できない項目は未確認とし、0点や成功へ置き換えず、そのscenarioの総合判定と達成率を未測定にする。
失敗には落ちたcriticalのIDと証拠を添える。

`tool_uses`や`duration_ms`を返さないAPIの値を推定で埋めない。
実metadata、tool-callの完全な記録、自己申告は別の出典として扱い、実行契約に従って不明な値を残す。
時間と操作数は補助であり、短縮だけで成果、restraint、停止条件を削らない。
tool-callが増えた場合はtaskの難度と実際の探索を読み、本文の経路不足なのか必要な証拠取得なのかを確かめる。
timeout、環境不良、fixture不良、judge不良を指示の失敗と混同しない。

## 4. 一つの原因を直す

対象ごとの失敗台帳に、pattern名、代表Issue、General Fix Rule、観測したiteration、既存の修正位置を残す。
同じRuleが再発したらentryを増やす前に、既存の指示が読まれないのか、適用条件が違うのか、判定文へ届いていないのかを調べる。
Understandingの欠落をExecutionの禁止則で埋めず、最初に詰まったphaseの入力、分岐、完了条件を直す。

修正前に、対象の判定ID、原因仮説、変更する場所、予想する観測差を一文で結ぶ。
一iterationは一テーマとし、同じ原因を直す関連変更はまとめるが、無関係な変更は混ぜない。
自然発火だけが悪い場合は本文を固定してdescriptionを直し、実行は成功しているのに発火しない場合は本文を増やさない。
descriptionの修正は失敗queryの単語を足すのでなく、そのqueryが表す意図と境界を明確にする。
本文を変えた場合はIteration 0の対応を更新する。

packageを書く枝では`writing-for-agents`を読み、共通の手順を本文へ、特定の枝だけに必要な詳細を一段のreferenceへ置く。
日本語の文を整える場合は`ja-writing`を使う。
決定的な処理以外をscriptへ押し込まず、既存ownerの規範やtool schemaを複製しない。
runtimeには自立した方法を書き、donorの紹介、作者名、来歴による実行指示を置かない。
revision、license、採用理由、非採用部分は既存の保守文書へ残す。
共有文書やmetadataを別ownerが持つ場合は、必要な変更と根拠をそのownerへ渡す。

## 5. 再実行して止める

同じ固定scenarioを新しい実行者で再実行し、修正で変わった判定と新しい不明瞭点を記録する。
自然発火は各queryを3回のfresh実行で観測し、発火数と全回の結果を示す。
暫定の判定は2回以上の発火をpositiveの成功、1回以下をnear-missの成功とし、重要な禁止やcriticalの失敗は多数決で隠さない。
この回数と境界は小規模な調整用の既定値であり、信頼性の保証ではない。

最終候補では節、reference、scriptを一つずつ外すablationを同じ判定で行い、成果が変わらない部分を戻さない。
Skill全体を外しても差がなければ、Skillを作らない、既存ownerへ統合する、またはretireする判断へ戻る。
本文の明示利用で差があっても自然発火しなければ、採用の成功として扱わない。

変更なしの確認を含め、全criticalが成功し、routing、restraint、compositionが退行せず、新しい不明瞭点も達成率の改善もないfresh roundが2回続いたら収束候補とする。
高重要度では3回を要する。
利用可能で同条件の効率metricだけを比較し、未取得なら品質面だけの収束と明示する。
holdoutを最後に実行し、固定したcriticalと境界を満たした場合だけ、そのmodeの収束を報告する。
holdoutが失敗したら採用せず、原因を開発scenarioへ移した新しい評価版と未使用のholdoutで続ける。
3回の修正でも同じpatternが続く場合は、禁止則を積まず契約か手順の構造を見直す。

評価の許可、公開API、証拠、事前に決めた実行枠が尽きたら停止し、収束とは区別する。
実行不能を自己再読で埋めず、source変更と未実施の評価を分けて返す。
形式validatorの成功だけで能力、自然発火、改善量を主張しない。

## 返す結果

mechanismと採否、変更したsource、固定した評価版とmode、対照の条件を返す。
iterationごとの変更テーマ、scenario別の成功か失敗か未確認、達成率、phase、criticalの証拠、振り返り、台帳更新、holdoutとablationの結果を示す。
実際に測った操作数と時間には出典を付け、未測定のbaseline、routing、composition、配送段を明記する。
採用、統合、retire、静的確認のみ、評価待ちを区別し、sourceが変わっただけで配備済みと報告しない。
