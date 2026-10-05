# Skill portfolio

**読み手:** Skill の責務境界、選定根拠、現在の導入状態を理解したい人。学習中に読む。

Skillは、反復する作業で基礎モデルより良い判断を再現する能力として置く。
候補名の一覧を完成形のtaxonomyとみなさず、代表scenarioで不足と改善を確認できたものだけ配備する。
外部Skillは、方法を再構成するdonorとして使う場合と、本文と資材をそのまま採用するsourceとして使う場合を区別する。

## 判断原則

Skill は原則として作らない。基礎モデル、repository policy、必要時に読む reference、決定的な script や tool、既存 Skill で不足が解消しない場合だけ候補にする。目標は Skill の数でなく、必要な能力と品質を満たす最小の所有物である。

調査は広く行い、runtime へ渡す知識は密に圧縮する。具体例から共通点と重要な差異を見つけ、仮の抽象を反例で壊してから採用する。分類表を先に作って空欄を埋めない。事実、解釈、判断、変更を分け、明示要件、正しさ、安全性、domain invariant、外部契約を満たす案の中で、凝集、結合、局所性、一貫性、変更容易性を比較する。

各 Skill は一つの明確な job と判断所有権を持つ。原則一つだけを Skill にせず、複数の仕事を隠した orchestrator も実証なしに作らない。同じ理由には同じ判断を適用し、異なる理由による差は残す。

## 構成上の配備対象

local Skillの正本は[`skills/<id>/skill/`](../../skills)である。
各`module.nix`がsource、`requiresSkills`、`requiresCapabilities`を`dotfiles.skills.registry`へ登録し、外部Skillも同じ契約を使う。
固定した外部sourceの取得は[`flake.nix`](../../flake.nix)、既存pluginの採用集合と依存宣言は[`skills/plugins/module.nix`](../../skills/plugins/module.nix)が所有する。
registryのsourceは`SKILL.md`があるdirectoryを指し、upstreamのrepository内での配置を共通化する必要はない。

donorはlocal Skillを作る判断材料であり、donorを参照しただけでは元のSkillを配備しない。
一方、直接採用ではupstreamの本文、reference、scriptを複製せず、同じIDのlocal版も明示的なNix option overrideで元の外部sourceへ戻せる。
供給元と依存metadataを選ぶowner、登録条件、差替手順は[外部リポジトリ所有Skillの構成](repository-skills.md)にまとめる。

Codexに同梱されるsystem `skill-creator`は、[`skills.config`](https://developers.openai.com/codex/config-reference#skillsconfig)で無効化し、localの`skill-design`だけをrouting対象にする。ClaudeとOpenCodeでも同等のローカル正本を使う。

```sh
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.skills.enabled
```

有効なSkillは[`skills/module.nix`](../../skills/module.nix)が、選択したCapabilityとSkill間依存を満たすregistry entryから導く。`dotfiles.skills.enabled`はread-onlyの内部派生値であり、Agent clientはこの有効集合だけを各client形式へ投影する。

MCP専用の薄いwrapperは置かない。`repository-research`は探索経路とsource検証、`browser-operation`は実surfaceの状態遷移と副作用境界、`github-operations`はidentity、pre-read、idempotency、不可逆操作、`memory`はrecallの検証、保存admission、privacy、failure fallbackを所有する。SkillとCapabilityの対応、subagentごとのrouteは[`agents/subagents/routing.nix`](../../agents/subagents/routing.nix)を正本にする。

## 体系と接尾辞

Skill名は作業の種類を表す接尾辞で統一する。

- `-writing`: 文章を生成、推敲する。
- `-analysis`: 証拠から原因、構造、影響を導く。
- `-review`: 既存成果物を規範と証拠で監査し、finding を出す。
- `-design`: 実装前に構造、契約、方針を決める。
- `-modeling`: 概念、状態、不変条件、語彙を定義する。
- `-research`: 外部事実やローカルリポジトリを探索、評価、検証する。
- `-operation`: 外部ツールや実サービス、基盤を安全に操作する。
- `-implementation`: 確定仕様やテスト、構造改善方針に基づいてコード変更を実装する。

基礎的な共通前提を持つ特殊な手順（`grilling`, `memory`）を除き、すべてのSkillはこの命名体系に従う。

| 種別 | 構成Skill |
|---|---|
| 特殊 | `grilling`、`memory` |
| implementation | `tdd-implementation`、`refactoring-implementation` |
| writing | `ja-writing`、`commit-writing`、`change-writing`、`description-writing`、`documentation-writing`、`comment-writing` |
| research | `web-research`、`repository-research` |
| operation | `browser-operation`、`github-operations` |
| analysis | `bug-analysis`、`dependency-analysis`、`impact-analysis`、`performance-analysis` |
| review | `code-review`、`security-review` |
| design | `skill-design`、`environment-design`、`ui-design`、`code-design`、`module-design`、`interface-design`、`error-design` |
| modeling | `domain-modeling` |
## 責務境界

`commit-writing` は一つのcommitが解決する問題と目的を履歴へ残す。`change-writing` は既に存在する差分を、PR、changelog、release noteの読み手へ説明する。`description-writing` はREADME、ADR、仕様、報告、技術解説を、読者の問いと文書の目的から構成する。差分固有の説明を一般文書へ混ぜない。

`documentation-writing` は宣言の契約を書く。目的と、該当する事前条件、事後条件、不変条件、副作用、失敗条件を扱う。`comment-writing` は実装コメントを書く前に、構造、命名、コード本体で表せないかを調べる。残すのは、自然に見える実装を採らなかった理由と、現在も有効な制約だけである。変更履歴、古いコード、処理の言い換えは扱わない。

`web-research` は外部の問いに対してsourceを探索、評価、比較し、引用可能な根拠を作る。`grilling` は未解決のproductやdomain判断を利用者との質問で詰める。domainの意味の確定と文書への記録は `domain-modeling` が所有する。外部事実の収集と、利用者が所有する決定を同じ仕事にしない。

`repository-research`は、表現や所在が不明なlocal概念、関係、複数fileのbehaviorを見つけ、現在のsourceでmaterial claimを検証する。既知のexact text、path、symbolはraw toolへ残し、依存graphは`dependency-analysis`、具体的変更のblast radiusは`impact-analysis`へ渡す。

`github-operations`は、GitHub MCPのaccount targetとresourceを一意にし、write前後のstate、曖昧な結果の再試行、merge、delete、history変更の直前確認を扱う。変更説明は`change-writing`、review判断は`code-review`、commit messageは`commit-writing`が所有する。

`memory`は、過去の記録を候補としてrecallし、一次sourceで検証してから採否を決める。保存対象は検証済みの訂正、確定方針、再利用patternに限り、secret、個人情報、推測、短期task情報を除く。memoryを正本やrepository調査の代替にしない。訂正をmemoryへ残すかどうかは決めない。

`environment-design`は、今の作業の外へ残す改善、訂正、教訓を主張に分け、architecture-standard、dotfiles-wslのagent能力、dotfiles-wslの基盤、upstream、対象project、memoryのうち一つの所有者へ振り分ける。所有者の現行本文を先に読み、既存の規律で足りれば規律を増やさず、読まれなかった、適用されなかった、誤読されたという原因の側へ振り分け直す。文面は各所有者の入口が決める。標準は作業checkoutの`standard-update`、dotfiles-wslのagent能力は`skill-design`へ渡し、標準の版の更新とrebuildを経てagentへ届くまでを閉じる。`skill-design`は、不足が規範の欠落や別repositoryの所有物にある場合に`environment-design`へ戻す。

`domain-modeling` は概念と語彙を定義する。`naming-review` は定義済みの意味を入力に、code、schema、DB、UI、文書の語彙、役割、単位、粒度を監査する。

`dependency-analysis` は node、edge、方向、granularity を定義して依存の事実を作る。`impact-analysis` は具体的な変更を起点に、code、data、runtime、deployment、契約、所有へ伝播する影響を導く。

`performance-analysis` は代表workloadと比較条件を固定し、分布、critical path、resource saturation、controlled probeからbottleneckを特定する。最適化の実装、一般的なcode監査、機能障害の原因分析は所有しない。

`ui-design`は、利用者の仕事、実際のcontent、既存design systemを入力に、情報階層、interaction、利用者に見えるstateとfeedback、visual、responsive、accessibilityを決め、実装前のbriefで止める。module-privateなcomponent treeとstate ownerは`code-design`が所有する。確定済みUIの実装には独立Skillを置かず、briefと既存design systemを制約とする通常の実装作業へ渡す。

`ui-review`候補は、利用者の仕事を実browserで遂行し、情報階層、interaction、visual、responsive、accessibility、content、feedback、recoveryを監査する。browserは証拠を得る手段であり、console、network、DOM、memory、securityを横断する`browser-review`は作らない。機能障害の原因は`bug-analysis`、性能は`performance-analysis`、セキュリティは`security-review`へ送る。forward evalが成立していないため、まだ配備しない。

`browser-operation`は、既知の利用者taskまたは受入条件を実browserで実行し、freshなsnapshot、DOM、console、network、必要なscreenshotから証拠を返す。UIの良否は判断せず、設計と監査は`ui-design`または`ui-review`候補、原因分析は`bug-analysis`、性能は`performance-analysis`へ渡す。

セキュリティreviewは`security-review`が所有する。脅威モデリング、脆弱性候補の発見、成立条件の検証、攻撃経路の追跡、修正の引き渡しまでを、単一Skill内のフェーズとリファレンス文書で所有する。

`code-design` は module 内部の型、関数、変換、純粋核と effect、抽象、局所性を決める。UI module内のmodule-privateなcomponent tree、props、state owner、composition、既存primitiveのreuseも同じ責務に含める。`module-design` は actor、change driver、責務、所有、境界、依存方向を決める。`interface-design` は確定済みの境界に、exact type、failure、side effect、ordering、互換性を持つconsumer-visible contractを与える。`architecture-design` は system 全体の topology、quality attribute、deployment、integration を決める。

`error-design`は、固定済みのmodule境界、責務owner、公開failure contractを入力に、owner内部のfailure表現、翻訳点、伝播、回復、集約、観測を決める。公開error shape、module間の責務配置、障害原因、reliability target、実装は所有しない。

`module-design`は、確定済みのactor、domain ownership、state、artifact lifecycle、system topologyを制約として消費する。module内部の実装、exact interface、serviceやrepositoryのtopology、domain語彙、既存構造のseverity付きreviewは所有しない。

`data-modeling`候補は、確定済みのdomainの意味を、正準形、valid state、lifecycle、serializationへ写す。`db-design`候補は、代表workloadから物理schema、constraint、access path、transaction、保存と復旧の受入条件を決める。既存databaseの監査は独立Skillにせず、対象engineの一次資料と既存review手段を使う。sourceからtargetへの移行手順は`migration`へ渡す。

`test-design` は risk、contract、oracle、test level、fidelity を決める。`tdd-implementation` は確定済みのbehaviorを一つのobservableな縦のsliceにし、意味のあるRED、最小GREEN、触れた範囲のREFACTORを反復する。原因未確定の障害、test suiteの監査、独立した構造変更は所有しない。

`refactoring-implementation` は保存するobservableと構造上の痛みを先に固定し、既存の安全網か必要最小限のcharacterizationを使って、一つの可逆な内部変更ずつ検証する。新しいbehavior、public contract、architecture、migrationは所有しない。TDD中の局所REFACTORは`tdd-implementation`に残す。

## Donor の扱い

独自Skillは、モデルが一から作った規則を正本にしない。donorの一次本文から、具体的なprocedure、failure mode、trade-off、counterexampleを抽出し、[`architecture-standard`](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) とこのrepositoryの制約に合わせて再構成する。donor不在か改善未確認の規則は、原則としてruntime Skillへ入れない。

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


### bug-analysisで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock diagnosing-bugs](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/diagnosing-bugs/SKILL.md) | MIT | 報告された症状を判別するfeedback signal、最小再現、予測を伴う仮説、正しいtest seam | clean reproがなければ仮説を禁じること、仮説を3から5件へ固定すること、修正工程の所有 |
| [Addy Osmani debugging-and-error-recovery](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/debugging-and-error-recovery/SKILL.md) | MIT | 証拠保全、recent change、boundary、working/broken比較、外部errorを未信頼dataとして扱うこと | 全failureへの固定手順、一般的なfallback実装、言語固有例、常時full suite実行 |
| [Superpowers systematic-debugging](https://github.com/obra/superpowers/blob/f2cbfbefebbfef77321e4c9abc9e949826bea9d7/skills/systematic-debugging/SKILL.md) | MIT | bad valueを生成元へ遡ること、一変数のprobe、正常例との差分 | 全technical issueへの強制、3回失敗でarchitecture問題とする閾値、根拠のない効果測定値、修正とTDDの所有 |

`bug-analysis`は分析結果を所有し、修正を所有しない。test、CLI、request、trace、差分、runtime観測のうち、症状を判別できる最小のsignalを選ぶ。再現不能なincidentでも観測済み証拠を捨てず、事実、仮説、不明点を分ける。原因はfailure siteではなく、最初に誤ったstateか契約違反として示す。近接scenarioは [`agents/fixtures/bug-analysis-skill.json`](../../agents/fixtures/bug-analysis-skill.json) に置く。


### dependency-analysisで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [architecture-standard dependency](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/concerns/dependency.md) | repository rootに表示なし | source dependencyとruntime callの方向を分けること、policyとdetailの所有から期待する方向を説明すること | すべての分析対象へ内向き依存、constructor injection、portを規範として適用すること |
| [Matt Pocock codebase-design](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/codebase-design) | MIT | dependencyの性質によってseam、substitution、testの意味が変わること | deep module化、adapter分類、HTML report、grillingを依存分析の成果にすること |
| [decomplect coupling](https://github.com/shanev/skills/blob/8fd6aaf4d16e9c1e6caa5bfd9ba8d3bb52864c7f/decomplect/references/coupling.md) | MIT | explicitで安定した依存は必要であり得ること、cycleや結合を具体的な変更、build、test、deploy costで確かめること | architecture finding、confidence閾値、修正案を依存分析が所有すること |

`dependency-analysis`は、node、edge、方向、granularityを先に定義し、source、call、data、runtime、build、deployment、ownershipの依存を型なしの一graphへ潰さない。fan-in、fan-out、cycle、transitive reachabilityは構造の事実であり、数値だけで欠陥とは判定しない。具体的な変更から影響を追う仕事は`impact-analysis`、構造の良否は`architecture-review`、新しい依存方向の決定は設計Skillへ渡す。

代表scenarioは[`agents/fixtures/dependency-analysis-skill.json`](../../agents/fixtures/dependency-analysis-skill.json)に置く。正規のmanifest、compiler、AST、service定義、runtime traceを優先する。表現や所在が不明な候補は`repository-research`へ渡し、exact textや構文patternの候補は`rg`や`ast-grep`で直接探索してsourceで確かめる。言語横断の抽出を装う専用scriptは作らず、repositoryが持つtoolを使う。


### impact-analysisで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [WondelAI working-with-legacy-code](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966/working-with-legacy-code) | MIT | change pointからobservableへ外向きに辿るeffect sketch、影響が収束するpinch point、compilerをimpact evidenceとして使うこと | legacy codeの変更手順、characterization test、dependency breaking、refactoring実装 |
| [Addy Osmani deprecation-and-migration](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/deprecation-and-migration/SKILL.md) | MIT | active consumerとtouchpointの確認、old/new共存、利用状況の観測、additive準備とdestructive除去の境界 | migration方式の選択、deadline、実行手順、無条件のdown migrationや固定pattern |
| [`dependency-analysis`](../../skills/dependency-analysis/skill/SKILL.md) | local | 型付きdependency graphを具体的変更のeffect pathの証拠として使うこと | repository全体のgraph作成を毎回やり直すこと |

`impact-analysis`は一つの変更前後を固定し、consumerが観測する契約差からcode、data、runtime、deployment、operation、test、docs、ownerへ外向きに影響を追う。確実な影響、条件付きの影響、未観測の外部consumerやdynamic edgeを分ける。変更fileの列挙、一般的なdependency map、migration実装、新しい設計は所有しない。

代表scenarioは [`agents/fixtures/impact-analysis-skill.json`](../../agents/fixtures/impact-analysis-skill.json) に置く。dependency upgradeでは`web-research`がversion固有の外部契約を調べ、`impact-analysis`がrepository内の利用と照合する。sourceのchangelogだけでlocal impactが確定したとはみなさない。


### performance-analysisで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [architecture-standard performance](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/concerns/performance.md) | repository rootに表示なし | 尺度、percentile、代表負荷、同等な環境を先に定め、同じ条件の前後を比べること | 性能目的の並列化にADRを要求すること、最適化実装を分析に含めること |
| [Matt Pocock diagnosing-bugs](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/diagnosing-bugs/SKILL.md) | MIT | performance regressionではlogでなくbaseline、profiler、query plan、bisect、differentialを使うこと | 機能障害の再現、修正、回帰testを性能分析が所有すること |
| [Addy Osmani performance-optimization](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/performance-optimization/SKILL.md) | MIT | 同じ条件で再測定し、run間varianceを越える差だけを採用すること、correctnessをmetricより先に守ること | frontend/backendの既知anti-pattern集、固定budget、最適化実装、常時monitoring追加 |
| [Vercel Optimize](https://github.com/vercel-labs/agent-skills/tree/b8caa260a420a73042e35521de4b5c8baf6446cc/skills/vercel-optimize) | 該当directoryとrepository rootにlicense表示なし | observability signalから調査範囲を絞り、数値、file、因果のclaimを元の証拠で検証すること | Vercel CLI、SKU、threshold gate、framework別allowlist、固定report workflow |
| [Addy Osmani web performance](https://github.com/addyosmani/web-quality-skills/blob/95d6e255afe1596b557d7a8498517884438f5b3a/skills/performance/SKILL.md) | MIT | browserのnetwork waterfall、main thread、runtime、fieldとlabの観測経路 | 固定resource budget、一般的なquick fix、Core Web Vitalsを全systemの基準にすること |

`performance-analysis`は、latency、throughput、CPU、memory、allocation、GC、I/O、database、network、build、browser性能に共通する測定と因果確認を所有する。尺度、workload、environment、revision、sampleを固定し、平均だけでなく分布とvarianceを見る。resource利用率とsaturation、wall timeとon-CPU time、live memoryとallocation、service timeとqueueingを分ける。

代表scenarioは[`agents/fixtures/performance-analysis-skill.json`](../../agents/fixtures/performance-analysis-skill.json)に置く。


### tdd-implementationのdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [architecture-standard implementation process](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/process/implementation.md)、[separation](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/principles/separation.md)、[construction](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/principles/construction.md)、[test methods](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/structure/tests/methods.md) | repository rootに表示なし | actor、use case、変更理由からwork unitを定めること、test listを一つの縦のsliceずつ進めること、接続済みの型だけをREDに数えること、GREENの痛みから責務配置を見直すこと、新しいcaseで既存caseの本文を保つこと | test technique全般、test strategy、commitの分割をTDDが所有すること、単一caseから抽象を作ること |
| [Matt Pocock tdd](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/tdd/SKILL.md) | MIT | public interfaceからbehaviorを検査すること、実装へ結合したtestとproduction計算を複製するoracleを避けること、REDを実測して一つの縦のsliceを実装すること | seamごとに利用者確認を必須にすること、refactoringをTDDのloopからすべて外すこと |
| [Addy Osmani test-driven-development](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/test-driven-development/SKILL.md) | MIT | repositoryのtest toolと規約を先に読むこと、REDの理由を確認すること、最小GREEN、GREEN中のREFACTOR、同じ成功済みcheckを無変更で繰り返さないこと | 固定のtest pyramid、全変更への一律発火、無条件のfull suite、test設計とbrowser検証の所有 |
| [Kent Beck Canon TDD](https://tidyfirst.substack.com/p/canon-tdd) | 記事本文に再利用license表示なし | Test Listから一項目だけをconcrete testにし、各GREENが明らかにした設計を次のtest選択へ戻すこと、test作成時は主にinterfaceを決めること | 全項目のtestを先に具体化すること、実装設計をTest Listへ混ぜること、必要以上のrefactoring |
| [Loglass「AIに先にテストを全部書かせる」はTDDじゃない](https://zenn.dev/loglass/articles/16745471ef55ff) | 記事本文に再利用license表示なし | AIによるtest一括作成と、短いcycleで設計を育てるTDDを別の方法として扱うこと | test一括作成をTDDと呼ぶこと、数分という固定cycle、SDDの構成をTDDへ持ち込むこと |

`tdd-implementation`は、既に意味と期待結果が決まったbehaviorを実装し、その具体的なcycleから触れた範囲の設計を改善する規律を所有する。
testを大量に先行作成せず、consumerが観測する一つのsliceについて、production変更前のRED、最小GREEN、触れた範囲のREFACTORを完結させる。
testの種類を選ぶ一般論、既存suiteの評価、原因分析、独立したrefactoringは別の仕事である。

SRPはclassの大きさでなく、actorと変更理由をsliceとownerへ対応させる判断として使う。OCPはinterfaceを増やす指示ではない。新しいcaseで既存caseのtestと本文を保ち、既存の直和や方針契約へ追加する。明示されたextension contractがない場合、一つのcaseから抽象を予測せず、複数の具体例から安定部分と変動部分を反証可能な形で確認してから最小のseamを置く。三つ目の同種要求は、その判断を行う目安であって絶対条件ではない。

代表scenarioは[`agents/fixtures/tdd-implementation-skill.json`](../../agents/fixtures/tdd-implementation-skill.json)に置く。


### refactoring-implementationのdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [WondelAI working-with-legacy-code](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966/working-with-legacy-code) | MIT | change pointとtest pointの分離、現在behaviorのcharacterization、安全網の後で構造変更とbehavior変更を分けること | Sprout、Wrap、dependency breakingを通常のrefactoringへ常用すること、書籍由来の固定workflow |
| [Addy Osmani code-simplification](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/code-simplification/SKILL.md) | MIT | outputだけでなくerror、side effect、orderingも保存すること、既存規約を読むこと、一変更ごとの検証、触れた範囲への限定 | 行数、nesting、function sizeの固定閾値、無条件のfull suite、PR分割の固定 |
| [architecture-standard refactoring](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/process/refactoring.md) | repository rootに表示なし | safety netが足りない場合のcharacterization、境界ごとのcheckpoint、testと参照追跡、契機になった痛みが消えた時点で止めること | 各段で全testを実行すること、一括rewriteとしての内部書き直し |
| [dotnet testability-obstacle](https://github.com/dotnet/skills/blob/7953ba85365219dc7df5d73634e1f9d0bfabf0b9/plugins/dotnet-test/skills/testability-obstacle/SKILL.md) | MIT | 既存seamの再利用、必要memberだけの最小抽象、public signatureとdefault wiringの保存、seam自体とbehaviorの別検証 | C#固有の`TimeProvider`、`AsyncLocal`、process-global mutable seam |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | MIT | 新しい所有物の前に、削除、標準機能、既存mechanism、既存dependencyで足りるかを問う変換選択のlens | 全coding taskへの強制、最短diffと最少fileの最適化、一実装interfaceの一律削除、reviewとauditのworkflow |

`refactoring-implementation`は、保存対象を選び、現在のbehaviorを観測できる安全網を成立させた後、一つの内部構造変更ずつ同じ証拠で検証する。
line countの削減や新しい抽象は成果ではない。
Matt Pocockの`improve-codebase-architecture`は新しいmodule構成を選ぶため、このSkillへ統合しない。

代表scenarioは[`agents/fixtures/refactoring-implementation-skill.json`](../../agents/fixtures/refactoring-implementation-skill.json)に置く。


### skill-designのdonor

`skill-design`は、基礎モデル、policy、reference、script、tool、既存Skillで不足を解消できるかを先に判断する。
独立したSkillを作る場合も、具体的な不足、mechanism、責務境界、routing、composition、restraint、ablationから要否を決める。

runtime本文は[admissionと評価](../../skills/skill-design/skill/references/admission-and-evaluation.md)だけを必要時に読み、外部sourceの採否は[provenance](../../skills/skill-design/skill/references/provenance.md)へ分ける。代表scenarioは[`agents/fixtures/skill-design-skill.json`](../../agents/fixtures/skill-design-skill.json)に置き、Skillを作らない判断と近接Skillへ渡す判断も成功として扱う。



### module-designで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock codebase-design](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/codebase-design) | MIT | 責務配置の異なる案、seamの位置とinterface内容の分離、同じ形式での比較、代表usageからのcaller burden確認 | 三案と複数subagentの固定、deep moduleの一律優先、既存testの削除 |
| [architecture-standard design、separation、dependency](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | actorとchange reason、隠す判断、state owner、source dependencyとruntime callの分離 | 固定layerとdirectory、全依存のinward化、port、DI、composition root、one-file-one-conceptの強制 |
| [Shane Vitarana decomplect](https://github.com/shanev/skills/tree/8fd6aaf4d16e9c1e6caa5bfd9ba8d3bb52864c7f/decomplect) | MIT | couplingのstrength、distance、volatility、ownership、shared stateとtemporal contractの実費 | functional coreの標準化、全依存のinversion、review finding形式 |
| [WondelAI software-design-philosophy、team-topologies](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966) | MIT | information hiding、change amplification、caller load、data、runtime、artifact ownership | deep moduleの一律優先、固定scoreとteam taxonomy、moduleとteamの一対一対応 |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | MIT | 新moduleなしと既存ownerを対照に置き、新境界がdistinct change driver、state、artifact lifecycle、ownershipを封じ込めるか問うこと | file数、diff、行数、標準libraryを常時優先すること、single implementation interfaceの一律否定 |

`module-design`は、actor、change driver、stateとartifact lifecycleを固定し、責務配置の異なる案をhard constraint、変更伝播、caller burden、runtime crossing、build、deploy、可逆性で比較する。moduleを増やすことも減らすことも目的にせず、同じ制約下で他案を支配する案か、優先するriskに対するtrade-offを選ぶ。

代表scenarioは[`agents/fixtures/module-design-skill.json`](../../agents/fixtures/module-design-skill.json)に置く。


### interface-designで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Addy Osmani api-and-interface-design](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/api-and-interface-design/SKILL.md) | MIT | contract-first、observable behavior、structured failure、inputとoutput、variantの明示 | REST path、field casing、pagination、TypeScript型、optional追加、DB trustの固定規則 |
| [Matt Pocock codebase-design](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/codebase-design) | MIT | signatureを越えるinterface、seamと内容の分離、caller usageとburdenによる比較 | deep moduleの一律優先、adapter数、旧test削除、固定数の案とsubagent |
| [architecture-standard contracts、effect](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | semantic sourceとbindingの分離、absence、variant、failure、readerとwriter別のcompatibility | 固定directory、常設DSL、pagination、REST、OpenAPI、problem+json、version配置の一律適用 |
| [dotnet-webapi](https://github.com/dotnet/skills/tree/7953ba85365219dc7df5d73634e1f9d0bfabf0b9/plugins/dotnet-aspnetcore/skills/dotnet-webapi) | MIT | 既存API style、requestとresponse、failureとcancellation、schemaと実requestの照合 | C#の型、結果型、middleware、folder、`.http` file、warning規則 |
| [Speakeasy writing-openapi-specs](https://github.com/speakeasy-api/skills/tree/d2eab5991ef881b39a26ab47432cf273c2c1abb5/skills/writing-openapi-specs) | Apache-2.0 | OpenAPIを正本にする場合のoperation、required、variant、response、content type、schema-valid example | SDK生成、命名、schema再利用、OpenAPIを汎用contract形式にすること |
| [effect-fp-skill](https://github.com/mikezupper/effect-fp-skill/tree/e3ee107dc4e8a301fbddea43e85d4d1404fa15fc) | CC BY 4.0 | expected failureとdefect、handlerが必要なfield、外部errorの翻訳 | Effect型、TaggedError、TypeScript、null禁止、全dependencyのservice化 |

`interface-design`は、固定済みのownerとseamに対し、consumerの代表usageからsemantic contractを決め、repositoryの既存bindingへexactに写す。existing source of truthを別名で複製せず、provider layoutやvendor errorを公開しない。互換性はreaderとwriterの向きごとに判定し、同時運用が必要な非互換contractだけをversion化する。

代表scenarioは[`agents/fixtures/interface-design-skill.json`](../../agents/fixtures/interface-design-skill.json)に置く。


### code-reviewで調査したsourceと採否

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock code-review](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/code-review/SKILL.md) | MIT | requirementとrepository standardの分離、scope固定、機械検証済みstyleの除外 | issue tracker、parallel agent、固定smell、diffだけを読むこと |
| [Addy Osmani code-review、doubt、simplification](https://github.com/addyosmani/agent-skills/tree/be42637c5af93fdc8526b68ec2f2651b930f316c/skills) | MIT | artifactとclaimの分離、反証、observable behavior、local convention | 万能review、数値threshold、固定cycle、multi-model、refactoring実行 |
| [Ponytail review](https://github.com/DietrichGebert/ponytail/blob/2ed6c52c9d7e5e56942508591085fd45dea277d3/.openclaw/skills/ponytail-review/SKILL.md) | MIT | 削除、直接実装、既存helper、標準機能を新しい所有物の対照にすること | LOCとdependency数の最小化、single implementation abstractionの一律否定 |
| [code-humanizer](https://github.com/LeonardNJU/code-humanizer/tree/8ffe07b2f1301f4285c9ccaed387bd203ff6ef4c)、[deai-code](https://github.com/golovatskygroup/deai-code/tree/35d9f87f25221577fdaa1b7f2ebb212d921dea5d) | MIT | 重複helper、broad exception、fallback、説明comment、投機的抽象を現在の変更costから疑うこと | AI著者推定、score、出自別severity、人間らしく見せる目的 |
| [architecture-standard review、audit](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de/process) | repository rootに表示なし | 機械検証の優先、未変更consumer、生成物、設定、今回導入した問題の因果 | project固有standardの本文、全severity見出し、finding数の強制 |

`code-review`は要件とrepositoryの制約を別に照合し、指定された差分が導入または悪化させた実害だけをfindingにする。
代表scenarioは[`agents/fixtures/code-review-skill.json`](../../agents/fixtures/code-review-skill.json)に置く。


static analysisは、repositoryのbuildとlintに組み込まれたanalyzerが対象sourceに出した診断を使う。
外部serverの解析結果は、解析したrevisionをreview対象へ対応付けられない限り根拠にしない。
差分が追加したsuppressionは、規則、範囲、理由が揃っているかを確かめる。

### code-designで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock codebase-design](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/codebase-design) | MIT | callerが知るcontractを入力制約にすること、private seam、abstractionのdeletion test、leverageとlocality | moduleのdeepening、interface再設計、固定数の案とsubagent、既存test削除 |
| [architecture-standard implementation、type、effect](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | canonical form、valid state、read-decide-write、resourceとcancel、事実と制約の分離 | module、public contract、domain、data、errorの再設計、effect system、event sourcing、実装workflowの強制 |
| [Shane Vitarana decomplect](https://github.com/shanev/skills/tree/8fd6aaf4d16e9c1e6caa5bfd9ba8d3bb52864c7f/decomplect) | MIT | semantics、具体的な変更とtest cost、比例したpure/effect分離、直接実装を残す対照 | diff review、severity、confidence、finding形式 |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | MIT | 既存物、native mechanism、導入済みdependency、新規所有物の順で問うこと | 常時発火、mode、行数、diff、標準libraryを最上位にすること |
| [Addy Osmani code-simplification](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/code-simplification/SKILL.md) | MIT | exact behavior、error、effect、ordering、project convention、clarity over compactness | simplification trigger、行数threshold、言語別recipe、commit workflow |
| [WondelAI software-design-philosophy、pragmatic-programmer](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966) | MIT | change amplification、cognitive load、unknown dependency、knowledge duplication、invariant | score、比率、public interface一般化、tracer bullet、見積りと組織規則 |
| [effect-fp-skill](https://github.com/mikezupper/effect-fp-skill/tree/e3ee107dc4e8a301fbddea43e85d4d1404fa15fc) | CC BY 4.0 | illegal state、parse once、edge処理、variant、resource lifecycle | Effect、TypeScript、Schema、Layer、全面immutable、全dependencyのservice化 |

`code-design`は、固定済みmoduleとexact interfaceを入力に、内部表現、function、data flow、algorithm、判断とeffectの配置を決める。既存mechanismか直接実装を対照にし、新しいprivate abstractionは実在する知識、変化、変更か検証costを局所化する場合だけ残す。実装、refactoring、TDD、reviewは所有しない。

代表scenarioは[`agents/fixtures/code-design-skill.json`](../../agents/fixtures/code-design-skill.json)に置く。


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


### error-designで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [architecture-standard effect、resilience、observability、contract](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | expected failure、defect、cancellationの分離、境界mapping、retry owner、failure isolation、effect境界の構造化観測 | effect system、固定構造、公開contractとreliability targetの再設計 |
| [effect-fp-skill](https://github.com/mikezupper/effect-fp-skill/tree/e3ee107dc4e8a301fbddea43e85d4d1404fa15fc) | CC BY 4.0 | failureごとのvariant、handlerに必要なcontext、外部errorの境界翻訳、validationとbatchの集約 | Effect、TypeScript、TaggedError、全dependencyのservice化、全I/Oのspan化 |
| [Addy Osmani API design、debugging and recovery](https://github.com/addyosmani/agent-skills/tree/be42637c5af93fdc8526b68ec2f2651b930f316c) | MIT | structured failure、外部errorを未信頼dataとして扱うこと、境界の観測context | HTTP規則、diagnosis workflow、blanket catch、safe defaultと一般fallback |
| [Matt Pocock codebase-design、diagnosing-bugs](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df) | MIT | interfaceにerror modeが含まれること、callerとtestが同じseamを使うこと | deep module、新しいseam、diagnosisと修正workflow |
| [WondelAI DDIA、Release It!、Pragmatic Programmer](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966) | MIT | faultとsystem failure、safety優先、policyが作るfailure、assertionとexpected errorの境界 | score、固定threshold、全integrationへの同じpattern、常設fallback、chaos実行 |
| [dotnet-webapi](https://github.com/dotnet/skills/tree/7953ba85365219dc7df5d73634e1f9d0bfabf0b9/plugins/dotnet-aspnetcore/skills/dotnet-webapi) | MIT | terminal handlerの観測責任、最終mapping、cancellationの伝播 | Problem Details、middleware、C#型、folder、OpenTelemetry設定 |

`error-design`は、扱いの異なるfailureだけを列挙し、意味を知るownerへ置き、provider errorを最初の既存boundaryで一度だけ翻訳する。処理できる場所まで意味を保ち、固定済みのretry、観測owner内で処理点を一つにする。後者は、donorのboundary処理とterminal handler責任を、このrepositoryの二重処理防止へ統合した判断である。共通Error型、Result、exception hierarchy、error registryを成果にせず、既存表現で足りる案を必ず対照にする。

代表scenarioは[`agents/fixtures/error-design-skill.json`](../../agents/fixtures/error-design-skill.json)に置く。


### domain-modelingで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock domain-modeling](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/domain-modeling) | MIT | 曖昧語への質問、具体的なedge case、codeとの矛盾確認、決定済み語彙の即時記録、ADRを残す三条件 | `CONTEXT.md`、`CONTEXT-MAP.md`、`docs/adr/`の固定配置と、一つの用語集形式 |
| [architecture-standard](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | 不変条件から整合性境界を考えること、事実と現在状態、識別子、時刻を区別すること、意味と単位を型へ伝える観点 | aggregate、型、純粋性、eventをすべてのdomain modelへ先に要求すること |

代表scenarioは[`agents/fixtures/domain-modeling-skill.json`](../../agents/fixtures/domain-modeling-skill.json)に置く。


### grillingで採用したdonor

| Donor | License | 採用した内容 | Local modification |
|---|---|---|---|
| [Matt Pocock grilling](https://github.com/mattpocock/skills/blob/85f83d3fde1d3a90d5c9a657f6998c79a6c37308/skills/productivity/grilling/SKILL.md) | MIT。配備package内に原文のnoticeを含める | decision tree、依存が解けたfrontier単位の質問、各問への推奨、一巡に複数問を置き区切り線で分けるtemplate、事実はagentが調べdecisionは利用者が決めること、共有理解まで実装しないこと | 事実確認のたびにsubagentを必須にせず、repositoryのsubagent規律に合わせた。emojiによる装飾は採らず、見出しと推奨の行だけを残した |

`grilling`は明示的な依頼を受け、未決定事項を依存順に質問するprocedureを所有する。
domainの意味とその記録は`domain-modeling`へ渡す。
代表scenarioは[`agents/fixtures/grilling-skill.json`](../../agents/fixtures/grilling-skill.json)に置く。



## Skill 化の条件

候補ごとに、Skillなしの代表scenarioで不足を観測する。
Skillありの同種scenarioで成果、routing、process、restraint、compositionを比較し、内容、reference、script、Skill自体を除いて結果が変わらなければ削除する。

外部sourceは採用時のrevision、license、採用理由、local modificationを追跡する。
sourceの分類や作者名をruntime構造に使わない。
local Skillの詳細な知識は一段のreferenceへ分け、`SKILL.md`には発火後に必要なprocedureと打ち切り条件を置く。
直接採用する外部Skillの資材はupstreamの構成を保ち、このrepositoryの本文へ移し替えない。
