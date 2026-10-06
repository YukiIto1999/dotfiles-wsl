# Skill portfolio

**読み手:** Skill の責務境界、選定根拠、現在の導入状態を理解したい人。学習中に読む。

Skillは、反復する作業の判断と手順を必要時に読む単位とする。
外部Skillを原文のまま採用する場合と、異なる仕事を持つcustom Skillの判断材料として参照する場合を区別する。
以下は採用構成と責務の説明であり、今回の切替による行動や品質の改善を実測した報告ではない。

## 判断原則

Skill は原則として作らない。基礎モデル、repository policy、必要時に読む reference、決定的な script や tool、既存 Skill で不足が解消しない場合だけ候補にする。目標は Skill の数でなく、必要な能力と品質を満たす最小の所有物である。

custom Skillを設計する際は調査を広く行い、runtimeへ渡す知識を密に圧縮する。
具体例から共通点と重要な差異を見つけ、仮の抽象を反例で壊してから採用する。
分類表を先に作って空欄を埋めない。
事実、解釈、判断、変更を分け、明示要件、正しさ、安全性、domain invariant、外部契約を満たす案の中で、凝集、結合、局所性、一貫性、変更容易性を比較する。

custom Skillは一つの明確なjobと判断所有権を持つ。
原則一つだけをSkillにせず、複数の仕事を隠したorchestratorも実証なしに作らない。
同じ理由には同じ判断を適用し、異なる理由による差は残す。

## 構成上の配備対象

local Skillの正本は[`skills/<id>/skill/`](../../skills)である。
各`module.nix`がsource、`requiresSkills`、`requiresCapabilities`を`dotfiles.skills.registry`へ登録し、外部Skillも同じ契約を使う。
固定した外部sourceの取得は[`flake.nix`](../../flake.nix)、既存pluginの採用集合と依存宣言は[`skills/plugins/module.nix`](../../skills/plugins/module.nix)が所有する。
registryのsourceは`SKILL.md`があるdirectoryを指し、upstreamのrepository内での配置を共通化する必要はない。

Matt PocockとPonytailのSkillは、原名のIDで固定sourceを直接採用し、本文、reference、scriptを書き換えない。
custom Skillが外部の考え方を参照していても、仕事が異なる限り、その参照だけを理由に上流Skillへ置き換えない。
供給元と依存metadataを選ぶowner、登録条件、差替手順は[外部リポジトリ所有Skillの構成](repository-skills.md)にまとめる。

Codexに同梱されるsystem `skill-creator`は、[`skills.config`](https://developers.openai.com/codex/config-reference#skillsconfig)で無効化し、localの`skill-design`だけをrouting対象にする。ClaudeとOpenCodeでも同等のローカル正本を使う。

```sh
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.skills.enabled
```

有効なSkillは[`skills/module.nix`](../../skills/module.nix)が、選択したCapabilityとSkill間依存を満たすregistry entryから導く。`dotfiles.skills.enabled`はread-onlyの内部派生値であり、Agent clientはこの有効集合だけを各client形式へ投影する。

MCP専用の薄いwrapperは置かない。`repository-research`は探索経路とsource検証、`browser-operation`は実surfaceの状態遷移と副作用境界、`github-operations`はidentity、pre-read、idempotency、不可逆操作、`memory`はrecallの検証、保存admission、privacy、failure fallbackを所有する。SkillとCapabilityの対応、subagentごとのrouteは[`agents/subagents/routing.nix`](../../agents/subagents/routing.nix)を正本にする。

## 直接採用

固定revisionの正本は[`flake.nix`](../../flake.nix)と[`flake.lock`](../../flake.lock)、採用IDとdirectory pathの正本は[`skills/plugins/module.nix`](../../skills/plugins/module.nix)である。
Orcaとarchitecture-standardに加え、次のMatt PocockとPonytailの原版を採用する。
sourceはrepository全体を保持し、rootのlicenseと同梱資材を残したままSkill directoryを配備先から参照する。

| Source | Flake input | 固定revision | License |
|---|---|---|---|
| [Matt Pocock skills](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df) | `mattSkills` | `8b78b531ab965735c5dc74f6f7a219e1e37326df` | [MIT](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/LICENSE) |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | `ponytail` | `2ed6c52c9d7e5e56942508591085fd45dea277d3` | [MIT](https://github.com/DietrichGebert/ponytail/blob/2ed6c52c9d7e5e56942508591085fd45dea277d3/LICENSE) |

次のpathは各固定sourceのrootからの相対pathであり、directoryの配置やSkill名をlocalの命名体系へ変換しない。

| ID | Source内のdirectory | 上流が所有する仕事 |
|---|---|---|
| `codebase-design` | Matt `skills/engineering/codebase-design` | deep module、interface、seam、testabilityの共通語彙と設計 |
| `diagnosing-bugs` | Matt `skills/engineering/diagnosing-bugs` | 障害と性能regressionのfeedback loop、再現、仮説、修正、regression test |
| `tdd` | Matt `skills/engineering/tdd` | 合意したpublic seamで、一つのtestと最小実装を進めるRED→GREEN |
| `domain-modeling` | Matt `skills/engineering/domain-modeling` | domain語彙を問い直し、`CONTEXT.md`とADRへ確定事項を記録 |
| `grilling` | Matt `skills/productivity/grilling` | 明示的な依頼に対するdesign treeとfrontier単位の質問 |
| `code-review` | Matt `skills/engineering/code-review` | fixed pointから`HEAD`までのStandardsとSpecの並列review |
| `improve-codebase-architecture` | Matt `skills/engineering/improve-codebase-architecture` | deepening候補のHTML reportと、選んだ候補のgrilling |
| `setup-matt-pocock-skills` | Matt `skills/engineering/setup-matt-pocock-skills` | projectごとのissue trackerとdomain文書の利用設定 |
| `research` | Matt `skills/engineering/research` | background agentによる一次資料の調査とMarkdownへの記録 |
| `ponytail` | Ponytail `skills/ponytail` | taskとcallerを理解した上で、既存物、標準機能、native機能、導入済みdependencyを優先 |
| `ponytail-review` | Ponytail `skills/ponytail-review` | 過剰設計の差分reviewと、削除候補と代替の提示 |

## Routing

旧local Skillの分割を維持するaliasやadapterは置かず、callerを次の入口へ移す。
同じIDだった`domain-modeling`、`grilling`、`code-review`もlocal版を残さず、上表の原版を使う。

| 旧local ID | 現在の入口 |
|---|---|
| `code-design`、`module-design`、`interface-design`、`error-design` | `codebase-design` |
| `bug-analysis`、`performance-analysis` | `diagnosing-bugs` |
| `tdd-implementation` | `tdd` |
| `refactoring-implementation` | 実装は`ponytail`、明示的なarchitecture探索は`improve-codebase-architecture` |

`diagnosing-bugs`は分析だけで止まるlocal版とは異なり、修正とregression testまで含む。
`tdd`はtest seamへの事前合意を要求し、refactoringをRED→GREENのloopに含めずreview段へ渡す。
`improve-codebase-architecture`と`setup-matt-pocock-skills`は上流の`disable-model-invocation: true`を保ち、明示的に呼び出すcommandとして使う。

`code-review`の対象は`git diff <fixed-point>...HEAD`で得るcommitted rangeであり、任意のstaged/unstaged差分を読む旧local reviewではない。
`verified-committed-range`には解決したfixed pointと対象`HEAD`のcommit SHA、Specの所在、実行済み検証の証拠を含める。
上流`code-review`のworkflowはtop-level callerが所有し、commit範囲の確認、StandardsとSpecの並列委譲、二軸を分けた集計を行う。
native subagentは再帰的にsubagentを起動できないため、`reviewer`は原版のStandardsまたはSpecのbriefと根拠を受け取る、read-onlyの単一軸workerとする。
`reviewer`の`code-review` routeは必須workflowではなくdynamicな参照であり、自分では再委譲や軸間の統合、順位付けをしない。
対象projectのissue tracker設定がない場合は上流の`setup-matt-pocock-skills`を使うため、`code-review`のSkill依存にも登録する。
未commit差分をreview対象へ含めるために無断でcommitせず、別sessionが作業中のcheckoutでは`HEAD`を動かさない。
`ponytail-review`は過剰設計だけを扱い、correctness、security、performanceのreviewを代替しない。

`browser-diagnostics`のCapability入口は`diagnosing-bugs`とする。
配備にはそのCapabilityと`browser-operation`の依存が必要であり、Capabilityを無効にしたhostには診断Skillを配備しない。
実browserの操作は`browser-operation`、GitHub resourceの取得や変更は`github-operations`など、環境側のroutingを通してgatewayのtoolを呼ぶ。
上流本文にあるtool名やcommand例を、別providerへの直通経路やpermissionの拡張として扱わない。
上流の簡略化や短いdiffの選好よりも、明示要件、正しさ、安全性、既存sessionの保護を優先する。

## Custom Skillの責務

writing系では、`commit-writing`がcommitの目的、`change-writing`が差分の説明、`description-writing`が読者の問いに沿うREADMEや技術文書の構成を所有する。
`documentation-writing`は宣言の契約、`comment-writing`は実装のWhy notと有効な制約、`ja-writing`は標準に沿う日本語の表現を扱う。
これらはcoding workflowの原版を別名へ分割したものではない。

`web-research`はURL探索、本文取得、library docsのtool選択と引用可能な根拠を扱い、上流`research`のbackground調査と記録に組み合わせる。
`repository-research`は未知のlocal概念や関係を探索し、現在のsourceでclaimを検証する。
既知のexact text、path、symbolはraw toolで直接調べ、依存graphは`dependency-analysis`、具体的変更のblast radiusは`impact-analysis`へ渡す。

`dependency-analysis`はnode、edge、方向、granularityを定義して依存の事実を作り、`impact-analysis`は一つの具体的変更からcode、data、runtime、deployment、契約、所有へ影響を追う。
deep moduleの設計やarchitecture探索とは成果物が異なるため、Matt由来の考え方を参照していても残す。

`browser-operation`は実surfaceの状態遷移と副作用境界、`github-operations`はaccount target、resource identity、write前後のstate、曖昧な結果、不可逆操作を所有する。
`memory`はrecallの一次source検証と保存admission、privacy、failure semanticsを扱い、repository調査や正本を代替しない。

`environment-design`は永続的な訂正や改善を標準、dotfiles、upstream、対象project、memoryの適切なownerへ振り分ける。
`skill-design`は基礎モデル、policy、reference、script、tool、既存Skillで足りるかを先に判断し、独立したSkillの要否とroutingを設計する。

`ui-design`は利用者の仕事、実content、既存design systemから、情報階層、interaction、visible state、feedback、responsive、accessibilityを実装前のbriefへ閉じる。
module内のcomponent構成やinterfaceは`codebase-design`へ渡し、確定したUIの実装を別のcustom Skillに分けない。
`security-review`は脅威モデリング、候補の発見、成立条件の検証、攻撃経路の追跡、修正への引渡しを所有する。

## Custom Skillの来歴

以下のdonorは、残すcustom Skillの異なる仕事に必要な判断材料である。
上流Skill全体の直接採用とは区別し、参照元、license、採った内容と採らなかった内容を残す。

### writing系で採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [architecture-standard](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | commitの直接目的、宣言の契約、実装commentのWhy not、文書種別と読者、記述の種類ごとの文末、定着した語、強調の絞り込み | 本文の複製。規則ごとに標準の所有fileを示し、Skillには読む時点、完了前の確認、失敗例だけを置いた |
| [japanese-tech-writing](https://gist.github.com/k16shikano/fd287c3133457c4fd8f5601d34aa817d/c7189cdc9c2520be50418209834145bdf3a46e97) | Gist本文に表示なし | 論証、段落、認知負荷、不確実性 | 書籍原稿向けの整形規則と本文の複製 |
| [stop-ai-slop-jp](https://github.com/iKora128/stop-ai-slop-jp/tree/e09d32796f253a62693885757cea484c275d06f2)、[slop-nuki](https://github.com/chezou/slop-nuki/tree/1bdf627b5991f4f806069619c9bde407960feac7) | MIT | 空句と定型構成の発見、読者と媒体に応じた語調 | AI著者判定、score、毒や揺らぎの強制、禁止語の機械適用 |
| [Anthropic doc-coauthoring](https://github.com/anthropics/skills/blob/f17010c9bb483898c1d9c9f42dde2b3a98889434/skills/doc-coauthoring/SKILL.md) | 該当directoryに個別表示なし | 読者、目的、既存template、重要文書のfresh-reader確認 | 全文書での質問数、brainstorm数、節ごとの固定workflow |
| [Keep a Changelog](https://github.com/olivierlacan/keep-a-changelog/tree/bb8a60462d3f0c760ee56df312fcfdc60cf6e2f2) | MIT | 利用者が観測する変更の分類と破壊的変更の移行情報 | commit typeだけによる自動分類と固定template |
| [natural-japanese](https://github.com/coji/natural-japanese/tree/0f1cc1c5a4e2aa7590598c88a15c213a60d9545a) | MIT | 一律改稿の禁止、地の文と箇条書きの使い分け、同型反復の打ち切り、英語統語の翻訳調 | 自然度score、見出しの結論化、文体憲法と文書型カタログの複製、形態素解析lint |

natural-japaneseは形態素解析による検出層を持つが、上流の[検証レポート](https://github.com/coji/natural-japanese/blob/0f1cc1c5a4e2aa7590598c88a15c213a60d9545a/corpus/reports/readability-sweep.md)は読みやすさ検出器の候補14件すべてを不採用にしている。上手な人間の文章に対するfalse positiveは表記ゆれ96.4%、句読点混在100%、冗長表現辞書25.5%である。弁別力が出た受身率、「が」の連鎖、こそあど密度は、下手な人間の文章をほとんど拾わないため撤回されている。残る弁別力はAI著者判定の指標であり、scoreを品質指標にしない方針と一致しない。このrepositoryにも検出器を置かず、規則だけを`ja-writing`へ入れた。

見出しは`description-writing`が所有し、拾い読みで引ける簡潔なラベルにする。結論や説明を文にして詰めない。


### web-researchで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock research](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/research/SKILL.md) | MIT | claimを一次資料まで辿り、sourceが直接支える範囲で結論を書く | 常にbackground agentを使うこと、調査のたびにfileを作ること |
| Context7、SearXNG、Crawl4AIの配備時tool schema | 該当なし。Context7とSearXNGは [`package.nix`](../../capabilities/library-documentation/context7/mcp/package.nix) と [`package.nix`](../../capabilities/web-discovery/searxng/mcp/package.nix)、Crawl4AIは [`module.nix`](../../capabilities/web-content/crawl4ai/backend/module.nix) の固定revisionから配備する | URL探索、本文取得、library docs、agent判断の分離と、実在する引数 | 配備されていないtool、SDK専用引数、固定件数のsource取得 |

代表scenarioと期待する探索経路は[`agents/fixtures/web-research-skill.json`](../../agents/fixtures/web-research-skill.json)に置く。


### dependency-analysisで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [architecture-standard dependency](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/concerns/dependency.md) | repository rootに表示なし | source dependencyとruntime callの方向を分けること、policyとdetailの所有から期待する方向を説明すること | すべての分析対象へ内向き依存、constructor injection、portを規範として適用すること |
| [Matt Pocock codebase-design](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/codebase-design) | MIT | dependencyの性質によってseam、substitution、testの意味が変わること | deep module化、adapter分類、HTML report、grillingを依存分析の成果にすること |
| [decomplect coupling](https://github.com/shanev/skills/blob/8fd6aaf4d16e9c1e6caa5bfd9ba8d3bb52864c7f/decomplect/references/coupling.md) | MIT | explicitで安定した依存は必要であり得ること、cycleや結合を具体的な変更、build、test、deploy costで確かめること | architecture finding、confidence閾値、修正案を依存分析が所有すること |

`dependency-analysis`は、node、edge、方向、granularityを先に定義し、source、call、data、runtime、build、deployment、ownershipの依存を型なしの一graphへ潰さない。
fan-in、fan-out、cycle、transitive reachabilityは構造の事実であり、数値だけで欠陥とは判定しない。
具体的な変更から影響を追う仕事は`impact-analysis`、依存方向やseamの設計は`codebase-design`へ渡す。

代表scenarioは[`agents/fixtures/dependency-analysis-skill.json`](../../agents/fixtures/dependency-analysis-skill.json)に置く。正規のmanifest、compiler、AST、service定義、runtime traceを優先する。表現や所在が不明な候補は`repository-research`へ渡し、exact textや構文patternの候補は`rg`や`ast-grep`で直接探索してsourceで確かめる。言語横断の抽出を装う専用scriptは作らず、repositoryが持つtoolを使う。


### impact-analysisで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [WondelAI working-with-legacy-code](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966/working-with-legacy-code) | MIT | change pointからobservableへ外向きに辿るeffect sketch、影響が収束するpinch point、compilerをimpact evidenceとして使うこと | legacy codeの変更手順、characterization test、dependency breaking、refactoring実装 |
| [Addy Osmani deprecation-and-migration](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/deprecation-and-migration/SKILL.md) | MIT | active consumerとtouchpointの確認、old/new共存、利用状況の観測、additive準備とdestructive除去の境界 | migration方式の選択、deadline、実行手順、無条件のdown migrationや固定pattern |
| [`dependency-analysis`](../../skills/dependency-analysis/skill/SKILL.md) | local | 型付きdependency graphを具体的変更のeffect pathの証拠として使うこと | repository全体のgraph作成を毎回やり直すこと |

`impact-analysis`は一つの変更前後を固定し、consumerが観測する契約差からcode、data、runtime、deployment、operation、test、docs、ownerへ外向きに影響を追う。確実な影響、条件付きの影響、未観測の外部consumerやdynamic edgeを分ける。変更fileの列挙、一般的なdependency map、migration実装、新しい設計は所有しない。

代表scenarioは [`agents/fixtures/impact-analysis-skill.json`](../../agents/fixtures/impact-analysis-skill.json) に置く。dependency upgradeでは`web-research`がversion固有の外部契約を調べ、`impact-analysis`がrepository内の利用と照合する。sourceのchangelogだけでlocal impactが確定したとはみなさない。


### skill-designのdonor

`skill-design`は、基礎モデル、policy、reference、script、tool、既存Skillで不足を解消できるかを先に判断する。
独立したSkillを作る場合も、具体的な不足、mechanism、責務境界、routing、composition、restraint、ablationから要否を決める。

runtime本文は[admissionと評価](../../skills/skill-design/skill/references/admission-and-evaluation.md)だけを必要時に読み、外部sourceの採否は[provenance](../../skills/skill-design/skill/references/provenance.md)へ分ける。代表scenarioは[`agents/fixtures/skill-design-skill.json`](../../agents/fixtures/skill-design-skill.json)に置き、Skillを作らない判断と近接Skillへ渡す判断も成功として扱う。



### ui-designで採用したdonor

`ui-design`は、利用者の仕事、実際のcontentと範囲、既存screenとdesign systemを先に読み、情報階層、interaction、visible state、feedback、recovery、responsive、accessibilityを一つのbriefへ閉じる。Impeccableのshape procedure、Hallmarkの既存system確認、Addy Osmaniのcontentとstate、WondelAIのaffordanceとmicrointeractionを組み合わせる。theme catalog、固定score、万能な禁止則、実装workflowは採らない。

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Impeccable shape](https://github.com/pbakaus/impeccable/blob/c8f476b330395031bc8f7a7aee8d848bc85c81e4/.agents/skills/impeccable/reference/shape.md) | Apache-2.0 | purpose、実content、範囲、stateから階層とinteractionを決め、briefで止める手順 | 固定質問round、theme catalog、script、全体orchestrator |
| [Hallmark](https://github.com/Nutlope/Hallmark/blob/13ac0ec7e148655948100b6396439e481361d690/skills/hallmark/SKILL.md) | MIT | 既存tokenとcomponentの確認、taskに対応する構造、架空metricの禁止 | 固定gate、theme catalog、rotation、cache、buildとauditの所有 |
| [Anthropic frontend-design](https://github.com/anthropics/claude-plugins-official/blob/ae21a9367949f92df4e31231d7efe43eaa08207c/plugins/frontend-design/skills/frontend-design/SKILL.md) | Apache-2.0 | purpose、audience、制約から一貫した方向を導くこと | 極端なaesthetic、特徴的font、motion、unexpected layout、code実装、毎回異なる外観の強制 |
| [Addy Osmani frontend-ui-engineering](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/frontend-ui-engineering/SKILL.md) | MIT | design system、content-first layout、semantic token、意味のある状態 | React構造、固定breakpoint、行数threshold、実装workflow |
| [WondelAI design-everyday-things](https://github.com/wondelai/skills/blob/6bac1534f9f256a56fc2b4dd0e70b9a692758966/design-everyday-things/SKILL.md)、[microinteractions](https://github.com/wondelai/skills/blob/6bac1534f9f256a56fc2b4dd0e70b9a692758966/microinteractions/SKILL.md) | MIT | affordance、signifier、mapping、constraint、feedbackと、trigger、rule、feedback、recovery | score、固定時間、signature moment、review severity |


pluginの`frontend-design`は、実装前にextreme aesthetic、特徴的なfont、motion、unexpected layoutを選び直すため、承認済みbriefと既存design systemを正本にできない。frontend実装に独立Skillが必要な不足も観測していないため、donorとしてだけ使い、配備しない。

代表scenarioは[`agents/fixtures/ui-design-skill.json`](../../agents/fixtures/ui-design-skill.json)に置く。


## Custom Skillの採用条件

候補ごとに、Skillなしの代表scenarioで不足を観測する。
Skillありの同種scenarioで成果、routing、process、restraint、compositionを比較し、内容、reference、script、Skill自体を除いて結果が変わらなければ削除する。

sourceの分類や作者名をruntime構造に使わない。
custom Skillの詳細な知識は一段のreferenceへ分け、`SKILL.md`には発火後に必要なprocedureと打ち切り条件を置く。
