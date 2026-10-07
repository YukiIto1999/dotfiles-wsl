---
name: skill-design
description: Decides whether a recurring agent capability deficit warrants a Skill, then creates, revises, or evaluates the smallest sufficient Skill package. Use when asked to turn a workflow or repeated correction into a Skill, change an existing Skill's responsibility or routing, compare it with baseline behavior, or audit Skill overlap and effectiveness. Starts with concrete scenarios and a mechanism gate, and permits a well-supported decision to create nothing. Does not build a portfolio from a taxonomy, install third-party Skills, turn a single principle or tool invocation into a Skill, or own the domain method that the candidate Skill will teach.
---

# 必要な能力だけをSkillにする

成果はSkillの追加ではなく、反復する不足を最小の所有物で解消した状態である。作らない判断を欠落として扱わない。

## 既存状況を読む

利用者の目的、反復するtask、過去の訂正、repository policy、既存Skillとその配備経路、reference、script、tool、評価方法を確認する。候補名や外部repositoryの分類から始めない。

不足がagentの再現ではなく、projectをまたぐ規範の欠落や、標準、upstream、対象projectが所有する内容にある場合は、主張、根拠のsource locator、現行本文との差を、利用可能な`environment-design`へ渡す。
返った所有者と入口に従い、agentの手順として残る不足だけをSkillの検討へ戻す。
利用できない場合は所有者を推測してSkillを作らず、確認できた不足と未確定の所有権を返す。

具体的な代表scenarioを集め、Skillなしで実行するか、既存の実行記録からbaselineを得る。事実、解釈、判断を分け、基礎モデルが失敗した箇所と成果への影響を記録する。想像上の不足だけなら止める。

## 最小のmechanismを選ぶ

次を順に比較する。

1. 何も追加せず、基礎モデルで処理する
2. 常時適用する短いrepository policyにする
3. 必要時だけ読むreferenceにする
4. 決定的な処理をscriptまたはtoolへ置く
5. 既存Skillをそのまま使うか、自然に補強する
6. 方法自体に固有価値があるsignature procedureを監査して採用する
7. 独立したcustom Skillを作る

機構の選択条件とSkill admissionの詳細は、判断が必要なときだけ[admission and evaluation](references/admission-and-evaluation.md)を読む。Skillが最小十分でなければ、採らない機構と理由を示して終了する。

## Candidateの契約を固定する

作る場合は、本文より先に次を一文ずつ定める。

- Job: 何を可能にするか
- Trigger: どの状況で必要か
- Decision ownership: 何を判断するか
- Evidence: 何を根拠にするか
- Outcome: 何が得られれば完了か
- Non-goals: 近接する何を所有しないか
- Distinct methodology: baselineや隣接Skillと異なる手順

同じ判断を複数Skillが所有する、triggerを自然に分けられない、独立利用に価値がない場合は統合する。trigger、判断所有権、evidence、単独利用が実質的に異なる場合だけ分ける。一原則だけのmicro Skillと、複数能力を隠すGod Skillは作らない。

## 方法と作業経路を決める

custom Skillで不足を埋める目的は、自己完結した独自の方法を定めることと、toolの利用や作業の進め方を定めることに分けて考える。
これは実taskに対する設計判断であり、frontmatterやregistryへ分類欄を増やすためのtaxonomyではない。
どちらも自分のJob、判断、成果を持ち、必要なら他の専門仕事と組み合わせる。

独自の方法では、観察、判断、推敲などを自分の手順で完了させる。
たとえば`ja-writing`は、内容、読者、用語、不確実性を保って日本語を整える。
正本の規範を読むことをtool workflowとみなさず、方法だけで成果を返せるtaskへ不要な検索や別Skillを強制しない。

作業経路では、いつどの能力を使い、得た証拠をどう評価し、次へ進むかを定める。
他のSkillが独立した専門判断を所有するなら、名前を紹介するだけでなく、その条件で実際に使うことを推奨する。
日本語の表現を整える`ja-writing`とのcompositionと、architecture-standardの適用が依頼されたときに対象と変更契約を渡して`standard-apply`の判定へ従うcompositionは、その目的に応じて成立する。

委譲する箇所には、発火する条件、渡す具体的な入力と証拠、必要な返却結果、その結果を採用して再開する地点を書く。
呼び出し側と委譲先で同じ判断を繰り返さず、連鎖するSkillにも根拠のlocator、前提、未確定事項を引き継ぐ。
`Read`、`Grep`、`Edit`、LSP、`Bash`などのprimitiveは直接使い、一回の操作を包むSkillを追加しない。

toolを使う場合は、その環境で宣言された公開MCP、CLI、Capabilityの契約を確認する。
論理的な操作名を実在するtool名やschemaと混同せず、container-backedな能力も公開Capability経由で使い、providerの内部process、database、containerへ直接入らない。
必要な能力が使えない場合は成功したことにせず、独立して完了できる部分を返し、どの判断にどの証拠か能力が足りないかを示す。
未確認の結果を埋めるfallbackは作らない。

`requiresSkills`は、全scenarioで実際に必要なcompositionだけを配備の前提にする。
条件付きの観測、言語別の補助、non-goalへのhandoffで、単独利用できる方法の配備を止めない。
本文と既存metadataが食い違う場合は、その無条件と条件付きの根拠を示し、metadataの所有者へ修正を渡す。

## 最小のpackageを書く

`description`をrouting contractとして、primary Job、主要trigger、重要な非対象を先に書く。本文は観察、判断、行動、referenceを読む条件、禁止事項、打ち切り、検証だけを持つ。sourceのtaxonomy、長い解説、一般論、評価harnessを移植しない。

詳細知識は一段だけのfocused referenceへ分ける。
決定的な抽出、検証、変換だけをscriptへ置き、意味判断を押し込まない。
`SKILL.md`と実行用referenceには、参考にしたSkillや作者の紹介、作者別の説明、来歴を根拠にした実行指示を入れない。
外部知見のrevision、license、採用理由、変更点は、runtimeから参照しないrepositoryの既存保守文書へ記録する。
現在の規範を所有する標準本文、公開toolの契約、実際に委譲する別Skillへの参照は残し、参考元の紹介とは区別する。

## Forward evalで存在理由を確かめる

baselineとSkillありの実行は、別の新しいsessionで行う。model、tool、repository、taskに必要なcontextを揃え、baselineの初期contextとSkill一覧には候補のname、description、本文、reference、候補から作った期待結果を含めない。Skillあり側でだけ候補を利用可能にする。入力、利用可能なSkill、model、実行結果は割り当て済み`TMPDIR`の評価用directoryへ残す。隔離条件を作れない場合は、baselineとupliftを推定せず「未測定」とする。

baselineで使った文面を写さず、同じ能力を要する新しいtypical scenario、境界事例、紛らわしいnear-missを使う。
scenarioごとに、必要な証拠、成果、行うべき委譲やtool操作、行ってはいけない操作を先に定め、実行結果と照合する。
方法だけで完了するtask、連鎖する専門仕事、必要なSkillやCapabilityが使えないtaskを、candidateの実際の利用条件に応じて含める。
成果だけでなくrouting、必要な証拠取得、restraint、隣接Skillとのcompositionを比較する。

典型例が改善してもnear-missを奪う、作業や説明を増やす、隣接Skillと判断を重複する場合は修正または棄却する。本文の節、reference、scriptを一つずつ外すablationを行い、成果が変わらないものは削る。最終的にSkill全体を外して差がなければSkillを削除する。

形式validatorはpackageの妥当性だけを示す。baselineとの差、routing、composition、restraintを実測していない状態を完成としない。実行不能、timeout、judgeやfixtureの不良はSkillの失敗と混同せず、未確認として残す。
