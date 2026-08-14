# Skill portfolio

**読み手:** Skill の責務境界、選定根拠、現在の導入状態を理解したい人。学習中に読む。

Skill は、反復する作業で基礎モデルより良い判断を再現する能力として置く。候補名の一覧を完成形の taxonomy とみなさず、代表 scenario で不足と改善を確認できたものだけ配備する。外部 Skill は完成品でなく、procedure、失敗例、判断材料を得る donor として扱う。

## 判断原則

Skill は原則として作らない。基礎モデル、repository policy、必要時に読む reference、決定的な script や tool、既存 Skill で不足が解消しない場合だけ候補にする。目標は Skill の数でなく、必要な能力と品質を満たす最小の所有物である。

調査は広く行い、runtime へ渡す知識は密に圧縮する。具体例から共通点と重要な差異を見つけ、仮の抽象を反例で壊してから採用する。分類表を先に作って空欄を埋めない。事実、解釈、判断、変更を分け、明示要件、正しさ、安全性、domain invariant、外部契約を満たす案の中で、凝集、結合、局所性、一貫性、変更容易性を比較する。

各 Skill は一つの明確な job と判断所有権を持つ。原則一つだけを Skill にせず、複数の仕事を隠した orchestrator も実証なしに作らない。同じ理由には同じ判断を適用し、異なる理由による差は残す。

## 構成上の配備対象

local Skill の正本は [`agents/shared/skills/`](../../agents/shared/skills) である。plugin source の revision は [`flake.nix`](../../flake.nix)、採用する plugin の選択は [`agents/module.nix`](../../agents/module.nix) が所有する。構成上の配備対象は次の command で取得する。

```sh
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.shared.skills --apply builtins.attrNames
```

2026-08-14 時点の構成は、次の Skill を配備対象にしている。rebuild 前の環境と起動済みagentには古い配備が残り得る。

- local: `bug-analysis`、`code-reviewer`、`commit-writing`、`change-writing`、`comment-writing`、`dependency-analysis`、`description-writing`、`documentation-writing`、`domain-modeling`、`grill-with-docs`、`grilling`、`impact-analysis`、`ja-writing`、`performance-analysis`、`web-research`
- plugin: `frontend-design`、`skill-creator`
- security plugin: `security-scan`、`threat-model`、`finding-discovery`、`validation`、`attack-path-analysis`、`fix-finding`

Superpowers は構成上の配備対象から除外した。以下は目標とする責務の候補群であり、既存Skillの継続、改修、rename、統合と、未実装の候補を含む。表の名前だけでは実装済みと判断しない。

## 候補群

名前の接尾辞は作業の種類を表す。

- `-writing`: 文章を生成、推敲する。
- `-analysis`: 証拠から原因、構造、影響を導く。
- `-review`: 既存成果物を規範と証拠で監査し、finding を出す。
- `-design`: 実装前に構造、契約、方針を決める。
- `-modeling`: 概念、状態、不変条件、語彙を定義する。

方法そのものを指す固有名は、この接尾辞へ無理に合わせない。

| 種別 | 候補 |
|---|---|
| 特殊 | `skill-creator`、`grilling`、`grill-with-docs`、`tdd`、`refactoring`、`prototype`、`migration` |
| writing | `ja-writing`、`commit-writing`、`change-writing`、`description-writing`、`documentation-writing`、`comment-writing` |
| research | `web-research` |
| analysis | `bug-analysis`、`dependency-analysis`、`impact-analysis`、`performance-analysis` |
| review | `code-review`、`architecture-review`、`test-review`、`interface-review`、`database-review`、`naming-review`、`ui-review`、`browser-review` |
| design | `ui-design`、`code-design`、`module-design`、`interface-design`、`architecture-design`、`db-design`、`component-design`、`test-design`、`error-design` |
| modeling | `domain-modeling`、`data-modeling` |

## 責務境界

`commit-writing` は一つのcommitが解決する問題と目的を履歴へ残す。`change-writing` は既に存在する差分を、PR、changelog、release noteの読み手へ説明する。`description-writing` はREADME、ADR、仕様、報告、技術解説を、読者の問いと文書の目的から構成する。差分固有の説明を一般文書へ混ぜない。

`documentation-writing` は宣言の契約を書く。目的と、該当する事前条件、事後条件、不変条件、副作用、失敗条件を扱う。`comment-writing` は実装コメントを書く前に、構造、命名、コード本体で表せないかを調べる。残すのは、自然に見える実装を採らなかった理由と、現在も有効な制約だけである。変更履歴、古いコード、処理の言い換えは扱わない。

`web-research` は外部の問いに対してsourceを探索、評価、比較し、引用可能な根拠を作る。`grill-with-docs` は未解決のproductやdomain判断を利用者との質問で詰め、共有理解をrepository文書へ残す。外部事実の収集と、利用者が所有する決定を同じ仕事にしない。

`domain-modeling` は概念と語彙を定義する。`naming-review` は定義済みの意味を入力に、code、schema、DB、UI、文書の語彙、役割、単位、粒度を監査する。

`dependency-analysis` は node、edge、方向、granularity を定義して依存の事実を作る。`impact-analysis` は具体的な変更を起点に、code、data、runtime、deployment、契約、所有へ伝播する影響を導く。

`performance-analysis` は代表workloadと比較条件を固定し、分布、critical path、resource saturation、controlled probeからbottleneckを特定する。最適化の実装、一般的なcode監査、機能障害の原因分析は所有しない。

`ui-review` は利用者の仕事を実画面で遂行し、情報階層、interaction、visual、responsive、accessibility、content、feedback、recovery を監査する。`browser-review` は console、network、storage、DOM、event、performance、memory、browser security、resource lifecycle を監査する。原因の特定は `bug-analysis` が所有する。

セキュリティreviewはpluginの`security-scan`が所有するため、別の`security-review`は作らない。read-onlyのsecurity agentはthreat model、finding discovery、validation、attack path、最終reportまでを所有する。検証済みまたは技術的に妥当なfindingの修正を明示された場合だけ、実装agentが別phaseで`fix-finding`を使う。

`code-design` は module 内部の型、関数、変換、純粋核と effect、抽象、局所性を決める。`module-design` は actor、change driver、責務、所有、境界、依存方向を決める。`interface-design` は境界を越える契約、`architecture-design` は system 全体の topology、quality attribute、deployment、integration を決める。

`data-modeling` はデータの意味、形、所有、正準形、valid state、lifecycle、serialization を決める。`db-design` は access pattern、物理schema、constraint、index、transaction、migration、rollout を決める。

`test-design` は risk、contract、oracle、test level、fidelity を決める。`tdd` は外から見た契約を先に置き、意味のある失敗、最小実装、refactoring を反復する進め方を所有する。

ここに境界を書いていない候補は、名前だけを仮置きした調査対象である。Job、trigger、判断所有権、根拠、完了条件、非責務を定めるまで実装しない。

## Donor の扱い

独自Skillは、モデルが一から作った規則を正本にしない。donorの一次本文から、具体的なprocedure、failure mode、trade-off、counterexampleを抽出し、[`architecture-standard`](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) とこのrepositoryの制約に合わせて再構成する。donor不在か改善未確認の規則は、原則としてruntime Skillへ入れない。

| Donor | 主に補強する候補 |
|---|---|
| [Matt Pocock skills](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df) | `bug-analysis`、`dependency-analysis`、`domain-modeling`、`code-design`、`module-design`、`code-review`、`tdd`、`prototype`、`web-research` |
| [Addy Osmani agent-skills](https://github.com/addyosmani/agent-skills/tree/be42637c5af93fdc8526b68ec2f2651b930f316c) | `impact-analysis`、`interface-design`、`code-review`、`tdd`、`bug-analysis`、`ui-design`、`performance-analysis`、security plugin |
| [WondelAI skills](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966) | `impact-analysis`、`refactoring`、`architecture-design`、`architecture-review`、`db-design`、`ui-review` |
| [dotnet skills](https://github.com/dotnet/skills/tree/7953ba85365219dc7df5d73634e1f9d0bfabf0b9) | `skill-creator`、`test-design`、`test-review`、`tdd` |
| [Vercel agent skills](https://github.com/vercel-labs/agent-skills/tree/b8caa260a420a73042e35521de4b5c8baf6446cc) | `component-design`、`performance-analysis`、`ui-review` |
| [Anthropic skills](https://github.com/anthropics/skills/tree/f17010c9bb483898c1d9c9f42dde2b3a98889434) | `skill-creator`、`ui-design`、`browser-review`、`description-writing` |
| [OpenAI Skills guidance](https://openai.com/academy/skills/) | `skill-creator`、routing評価、MCPを含むworkflow packaging |
| [PlanetScale database skills](https://github.com/planetscale/database-skills/tree/af0ce0cfb65cca4cc21d18ca0d9cf270ca99d488) | `db-design`、`database-review`、`migration` |
| [Supabase agent skills](https://github.com/supabase/agent-skills/tree/v0.1.8) | `db-design`、`database-review`、security plugin、`migration` |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | `code-design`、`module-design`、`refactoring`、`code-review`、`skill-creator` |
| [decomplect](https://github.com/shanev/skills/tree/8fd6aaf4d16e9c1e6caa5bfd9ba8d3bb52864c7f/decomplect)、Clairvoyance | `dependency-analysis`、`module-design`、`architecture-design`、`architecture-review`。Clairvoyanceは採用前にsourceを固定する |
| [effect-fp-skill](https://github.com/mikezupper/effect-fp-skill) | `code-design`、`data-modeling`、`error-design`。Effect固有APIは汎用規則にしない |
| [Hallmark](https://github.com/Nutlope/Hallmark)、[Impeccable](https://github.com/pbakaus/impeccable) | `ui-design`、`ui-review` |
| [japanese-tech-writing](https://gist.github.com/k16shikano/fd287c3133457c4fd8f5601d34aa817d)、[stop-ai-slop-jp](https://github.com/iKora128/stop-ai-slop-jp)、[slop-nuki](https://github.com/chezou/slop-nuki) | `ja-writing` |
| [code-humanizer](https://github.com/LeonardNJU/code-humanizer)、[deai-code](https://github.com/golovatskygroup/deai-code) | 品質判断だけを `code-review` に使い、著者推定を除く |
| [differential-review](https://github.com/trailofbits/skills/tree/main/plugins/differential-review) | security plugin |
| writing-openapi-specs | raw OpenAPIを扱う場合の `interface-design`、`interface-review` reference。採用前にsourceを固定する |

Ponytailは、削除、標準機能、既存機構、既存依存、新しい所有物の順に解決手段を問い直す。全coding taskへ強制するSkillとしては採らず、追加によって問題を解いたように見せる傾向を補正するlensとして各候補へ配る。

文章、code、UIのslopを一つのSkillへ統合しない。文章は主張と根拠、codeはcorrectnessと変更コスト、UIは利用者の仕事とinteractionを基準にする。AIらしさや著者推定のscoreは品質指標に使わない。

上流Skillを直接採用するのは、分解すると方法自体の価値を失うsignature procedureに限る。`grill-with-docs`は、薄いwrapper、依存先、license、固定revision、compositionを確認した上で採用した。

候補の発見には、次の会話記録も使った。会話内の結論は一次資料や正本ではなく、調査対象と反例を得るための入力として扱う。

- [AIらしさ、設計判断、一貫性](https://chatgpt.com/share/6a7d14a7-5ed0-83ee-9f50-a7c178a9e282)
- [Skill候補の横断調査](https://chatgpt.com/share/6a7d14b9-b444-83ee-9dbe-d6eb7458758d)
- [Matt、Addy、Web品質、WondelAI](https://chatgpt.com/share/6a7d1c95-beb8-83e8-ac31-24016faef00d)

### writing系で採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [architecture-standard](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | commitの直接目的、宣言の契約、実装commentのWhy not、文書種別と読者 | 本文の複製。local Skillの短い手順へ再構成した |
| [japanese-tech-writing](https://gist.github.com/k16shikano/fd287c3133457c4fd8f5601d34aa817d/c7189cdc9c2520be50418209834145bdf3a46e97) | Gist本文に表示なし | 論証、段落、認知負荷、不確実性 | 書籍原稿向けの整形規則と本文の複製 |
| [stop-ai-slop-jp](https://github.com/iKora128/stop-ai-slop-jp/tree/e09d32796f253a62693885757cea484c275d06f2)、[slop-nuki](https://github.com/chezou/slop-nuki/tree/1bdf627b5991f4f806069619c9bde407960feac7) | MIT | 空句と定型構成の発見、読者と媒体に応じた語調 | AI著者判定、score、毒や揺らぎの強制、禁止語の機械適用 |
| [Anthropic doc-coauthoring](https://github.com/anthropics/skills/blob/f17010c9bb483898c1d9c9f42dde2b3a98889434/skills/doc-coauthoring/SKILL.md) | 該当directoryに個別表示なし | 読者、目的、既存template、重要文書のfresh-reader確認 | 全文書での質問数、brainstorm数、節ごとの固定workflow |
| [Keep a Changelog](https://github.com/olivierlacan/keep-a-changelog/tree/bb8a60462d3f0c760ee56df312fcfdc60cf6e2f2) | MIT | 利用者が観測する変更の分類と破壊的変更の移行情報 | commit typeだけによる自動分類と固定template |

### writing系の代表scenario

2026-08-13に、旧Skillと基礎モデルを次の近接scenarioで比較した。自動scoreは使わず、出力と発火境界を確認した。再評価する入力と期待結果は [`agents/fixtures/writing-skills.json`](../../agents/fixtures/writing-skills.json) に置く。

| Scenario | 変更前の不足 | 変更後の結果 |
|---|---|---|
| staged diffからcommit messageを書く | 複数目的ならwriterがindexを変更する指示だった | 一つの目的とrevert理由を確認し、indexを変更しない |
| 明示したdiffからPR本文を書く | branch全体を固定で読み、空の`Related: none`と未実行checkを要求した | 明示範囲だけを読み、目的、主要変更、実行済み検証、実在する影響だけを書いた |
| 宣言commentと実装commentを書く | 専用Skillがなく、契約と実装説明を分けてrouteできなかった | 宣言は前提、冪等性、副作用、既知の失敗を記述し、実装commentは採らない指数backoffと`Retry-After`制約の一文だけにした |
| 曖昧な変数名を直す | コメント系Skillとの境界が未定義だった | `documentation-writing`、`comment-writing`、`ja-writing`はいずれも発火しなかった |
| READMEとrelease changelogをrouteする | PRとchangelogが別の固定templateだった | READMEは`description-writing`、release changelogは`change-writing`へ分けた |
| 顧客向けの丁寧なincident報告を書く | 旧`ja-writing`は語尾の均一化を避ける規則が、明示された敬体と競合した | 読者、媒体、明示された語調を優先し、事実と不確実性だけを保った |

評価中に実行したのは、Skill出力の比較、全local Skillへの`quick_validate.py`、`git diff --check`、配備contractのfocused checkだけである。評価のためのSkillや恒久workflowは追加していない。

### web-researchで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock research](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/research/SKILL.md) | MIT | claimを一次資料まで辿り、sourceが直接支える範囲で結論を書く | 常にbackground agentを使うこと、調査のたびにfileを作ること |
| Context7、SearXNG、Crawl4AIの配備時tool schema | 該当なし。Context7とSearXNGは [`package.nix`](../../mcp/context7/package.nix) と [`package.nix`](../../mcp/searxng/package.nix)、Crawl4AIは [`module.nix`](../../containers/crawl4ai/module.nix) の固定revisionから配備する | URL探索、本文取得、library docs、agent判断の分離と、実在する引数 | 配備されていないtool、SDK専用引数、固定件数のsource取得 |

旧`web-researcher`は、正規仕様一件で決まる問いにも複数sourceを要求し、指定URLの要約でも検索を始めた。`time_range`を最新判定に使い、解消可能な矛盾も両論併記した。さらに、言語指定、JavaScript実行、PDF、本文filterの説明が現行MCP schemaと一致していなかった。

`web-research`は問いに応じて、指定URLの直接取得、既知の一次資料、Context7、探索型調査を選ぶ。source数は固定せず、規範的な値を一つの現行仕様が所有する場合は一件で止める。近接scenarioと期待する経路は [`agents/fixtures/web-research-skill.json`](../../agents/fixtures/web-research-skill.json) に置く。実環境ではSearXNGへ`site:agentskills.io specification`を渡しても公式domainが結果に出なかった。一方、Crawl4AIは既知の正規URL `https://agentskills.io/specification` から本文、title、主要節、取得成功状態を返した。この差も、検索と本文取得を別の能力として扱う理由である。

### bug-analysisで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock diagnosing-bugs](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/diagnosing-bugs/SKILL.md) | MIT | 報告された症状を判別するfeedback signal、最小再現、予測を伴う仮説、正しいtest seam | clean reproがなければ仮説を禁じること、仮説を3から5件へ固定すること、修正工程の所有 |
| [Addy Osmani debugging-and-error-recovery](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/debugging-and-error-recovery/SKILL.md) | MIT | 証拠保全、recent change、boundary、working/broken比較、外部errorを未信頼dataとして扱うこと | 全failureへの固定手順、一般的なfallback実装、言語固有例、常時full suite実行 |
| [Superpowers systematic-debugging](https://github.com/obra/superpowers/blob/f2cbfbefebbfef77321e4c9abc9e949826bea9d7/skills/systematic-debugging/SKILL.md) | MIT | bad valueを生成元へ遡ること、一変数のprobe、正常例との差分 | 全technical issueへの強制、3回失敗でarchitecture問題とする閾値、根拠のない効果測定値、修正とTDDの所有 |

`bug-analysis`は分析結果を所有し、修正を所有しない。test、CLI、request、trace、差分、runtime観測のうち、症状を判別できる最小のsignalを選ぶ。再現不能なincidentでも観測済み証拠を捨てず、事実、仮説、不明点を分ける。原因はfailure siteではなく、最初に誤ったstateか契約違反として示す。近接scenarioは [`agents/fixtures/bug-analysis-skill.json`](../../agents/fixtures/bug-analysis-skill.json) に置く。

旧Superpowersとdonor本文を同じscenarioへ適用すると、診断依頼でも修正とTDDまで所有し、performanceだけの問題や原因確定後の実装でも発火した。clean reproがないincidentでは、既存logを分析する前に仮説を禁じる。新しいSkillは、診断と修正、機能障害とperformance分析を分け、再現できない場合も観測済み証拠から確定事項と不足を返す。

### dependency-analysisで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [architecture-standard dependency](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/concerns/dependency.md) | repository rootに表示なし | source dependencyとruntime callの方向を分けること、policyとdetailの所有から期待する方向を説明すること | すべての分析対象へ内向き依存、constructor injection、portを規範として適用すること |
| [Matt Pocock codebase-design](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/codebase-design) | MIT | dependencyの性質によってseam、substitution、testの意味が変わること | deep module化、adapter分類、HTML report、grillingを依存分析の成果にすること |
| [decomplect coupling](https://github.com/shanev/skills/blob/8fd6aaf4d16e9c1e6caa5bfd9ba8d3bb52864c7f/decomplect/references/coupling.md) | MIT | explicitで安定した依存は必要であり得ること、cycleや結合を具体的な変更、build、test、deploy costで確かめること | architecture finding、confidence閾値、修正案を依存分析が所有すること |

`dependency-analysis`は、node、edge、方向、granularityを先に定義し、source、call、data、runtime、build、deployment、ownershipの依存を型なしの一graphへ潰さない。fan-in、fan-out、cycle、transitive reachabilityは構造の事実であり、数値だけで欠陥とは判定しない。具体的な変更から影響を追う仕事は`impact-analysis`、構造の良否は`architecture-review`、新しい依存方向の決定は設計Skillへ渡す。

代表scenarioは [`agents/fixtures/dependency-analysis-skill.json`](../../agents/fixtures/dependency-analysis-skill.json) に置く。正規のmanifest、compiler、AST、service定義、runtime traceを優先し、`rg`や`ast-grep`の一致は候補としてsourceで確かめる。言語横断の抽出を装う専用scriptは作らず、repositoryが持つtoolを使う。

baselineでは、agent resource reaperの保持日数と実行間隔がNix option、package、systemd unit、observation、checkへどう伝播するかを調べた。最初の検索結果はsource参照、生成、runtime起動、文書、検査を混在させ、node、edge、方向、granularityを調査後に後付けした。型付きedgeへ分けると、保持日数はpackageへ埋め込まれる一方、実行間隔はtimer unitだけへ投影され、observationはtimer名しか参照しないと区別できた。文字列探索だけではNix evaluationによるconsumerの網羅性を証明できず、activation時の挙動も未確認として残った。

### impact-analysisで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [WondelAI working-with-legacy-code](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966/working-with-legacy-code) | MIT | change pointからobservableへ外向きに辿るeffect sketch、影響が収束するpinch point、compilerをimpact evidenceとして使うこと | legacy codeの変更手順、characterization test、dependency breaking、refactoring実装 |
| [Addy Osmani deprecation-and-migration](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/deprecation-and-migration/SKILL.md) | MIT | active consumerとtouchpointの確認、old/new共存、利用状況の観測、additive準備とdestructive除去の境界 | migration方式の選択、deadline、実行手順、無条件のdown migrationや固定pattern |
| [`dependency-analysis`](../../agents/shared/skills/dependency-analysis/SKILL.md) | local | 型付きdependency graphを具体的変更のeffect pathの証拠として使うこと | repository全体のgraph作成を毎回やり直すこと |

`impact-analysis`は一つの変更前後を固定し、consumerが観測する契約差からcode、data、runtime、deployment、operation、test、docs、ownerへ外向きに影響を追う。確実な影響、条件付きの影響、未観測の外部consumerやdynamic edgeを分ける。変更fileの列挙、一般的なdependency map、migration実装、新しい設計は所有しない。

代表scenarioは [`agents/fixtures/impact-analysis-skill.json`](../../agents/fixtures/impact-analysis-skill.json) に置く。dependency upgradeでは`web-research`がversion固有の外部契約を調べ、`impact-analysis`がrepository内の利用と照合する。sourceのchangelogだけでlocal impactが確定したとはみなさない。

baselineでは、agent resource reaperの公開optionと内部contract fieldを、意味と値を保ったまま改名する影響を調べた。option宣言、contract組立、package入力、check fixtureは確実に追随する一方、Shell変数、ledger schema、削除時期は変更不要と区別できた。repository外のoption consumer、derivation hash、switch時のunit再起動は、静的検索だけでは確定できなかった。dependency path上にあることと、observableが実際に変わることを分け、改名、削除、意味変更を別のchange contractとして扱う必要があった。

### performance-analysisで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [architecture-standard performance](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/concerns/performance.md) | repository rootに表示なし | 尺度、percentile、代表負荷、同等な環境を先に定め、同じ条件の前後を比べること | 性能目的の並列化にADRを要求すること、最適化実装を分析に含めること |
| [Matt Pocock diagnosing-bugs](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/diagnosing-bugs/SKILL.md) | MIT | performance regressionではlogでなくbaseline、profiler、query plan、bisect、differentialを使うこと | 機能障害の再現、修正、回帰testを性能分析が所有すること |
| [Addy Osmani performance-optimization](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/performance-optimization/SKILL.md) | MIT | 同じ条件で再測定し、run間varianceを越える差だけを採用すること、correctnessをmetricより先に守ること | frontend/backendの既知anti-pattern集、固定budget、最適化実装、常時monitoring追加 |
| [Vercel Optimize](https://github.com/vercel-labs/agent-skills/tree/b8caa260a420a73042e35521de4b5c8baf6446cc/skills/vercel-optimize) | 該当directoryとrepository rootにlicense表示なし | observability signalから調査範囲を絞り、数値、file、因果のclaimを元の証拠で検証すること | Vercel CLI、SKU、threshold gate、framework別allowlist、固定report workflow |
| [Addy Osmani web performance](https://github.com/addyosmani/web-quality-skills/blob/95d6e255afe1596b557d7a8498517884438f5b3a/skills/performance/SKILL.md) | MIT | browserのnetwork waterfall、main thread、runtime、fieldとlabの観測経路 | 固定resource budget、一般的なquick fix、Core Web Vitalsを全systemの基準にすること |

`performance-analysis`は、latency、throughput、CPU、memory、allocation、GC、I/O、database、network、build、browser性能に共通する測定と因果確認を所有する。尺度、workload、environment、revision、sampleを固定し、平均だけでなく分布とvarianceを見る。resource利用率とsaturation、wall timeとon-CPU time、live memoryとallocation、service timeとqueueingを分ける。

代表scenarioは [`agents/fixtures/performance-analysis-skill.json`](../../agents/fixtures/performance-analysis-skill.json) に置く。baselineでは、同じ負荷のrelease A/Bでcheckout APIのp95が186msから442msへ悪化したartifactから、`reserve_inventory`のsequential scanをbottleneckとして特定できた。一方、closed workloadからproductionへの外挿、run間variance、observer effectを判断手順として固定していなかった。新しいSkillは比較可能性と測定誤差を先に扱い、critical path上の時間差とcontrolled probeが同じ指標を動かした場合だけbottleneckと判定する。plan選択理由のような未確定のroot causeは、箇所の特定と分けて残す。

### domain-modelingで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock domain-modeling](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/domain-modeling) | MIT | 曖昧語への質問、具体的なedge case、codeとの矛盾確認、決定済み語彙の即時記録、ADRを残す三条件 | `CONTEXT.md`、`CONTEXT-MAP.md`、`docs/adr/`の固定配置と、一つの用語集形式 |
| [architecture-standard](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | 不変条件から整合性境界を考えること、事実と現在状態、識別子、時刻を区別すること、意味と単位を型へ伝える観点 | aggregate、型、純粋性、eventをすべてのdomain modelへ先に要求すること |

MattのSkillは、modelを変える仕事と既存語彙を読むだけの仕事を分ける点で有効だった。一方、文書配置をSkillが決めるため、このrepositoryの既存構成と衝突する。新しい`domain-modeling`は具体的なscenarioから概念、context、語彙、不変条件を決め、code、schema、API、UI、testの意味を照合する。実装上の型、module、table、endpointは後続の設計へ渡す。

代表scenarioは [`agents/fixtures/domain-modeling-skill.json`](../../agents/fixtures/domain-modeling-skill.json) に置く。近接する語彙の監査、DB schema設計、module境界設計、既存用語集の参照では発火しない。baselineは個人、組織、取消、返金を分離できたが、`Customer Organization`と`Representation`を利用者が意味を確定する前に正規語として採用し、観測事実だけでは決まらない不変条件を並べた。このSkillは、具体的なscenarioで反証し、観測と利用者判断を分けてからmodelを確定する手順を補う。

### grill-with-docsで採用したdonor

| Donor | License | 採用した内容 | Local modification |
|---|---|---|---|
| [Matt Pocock grill-with-docs](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/grill-with-docs/SKILL.md) | MIT。配備package内に原文のnoticeを含める | `grilling`を`domain-modeling`と合成する一文のwrapperを本文ごと採用 | 共有frontmatter契約にない`disable-model-invocation`を除き、自動発火を防ぐ境界をdescriptionへ移した |
| [Matt Pocock grilling](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/productivity/grilling/SKILL.md) | MIT。配備package内に原文のnoticeを含める | decision tree、依存が解けたfrontier単位の質問、各問への推奨、事実はagentが調べdecisionは利用者が決めること、共有理解まで実装しないこと | 事実確認のたびにsubagentを必須にせず、repositoryのsubagent規律に合わせた。質問の装飾だけを簡素化した |

`grilling`は明示的な依頼を受け、未決定事項を依存順に質問するprocedureを所有する。domainの意味は決めず、設計文書も書かない。`grill-with-docs`は独自の判断を持たず、二つを合成するsignature procedureとして置く。通常の設計、直接実装、候補を広げるだけのbrainstormでは発火しない。代表scenarioは [`agents/fixtures/grilling-skill.json`](../../agents/fixtures/grilling-skill.json) に置く。baselineは一問ごとに回答を待ち、同じ前提から今決められる他の論点と、後続の依存関係を示さなかった。このSkillは同じfrontierを一巡にまとめ、回答に依存する質問だけを後へ送る。

## Skill 化の条件

候補ごとに、Skillなしの代表scenarioで不足を観測する。Skillありの同種scenarioで成果、routing、process、restraint、compositionを比較する。内容、reference、script、Skill自体を除いて結果が変わらなければ削除する。

外部sourceは採用時のrevision、license、採用理由、local modificationを追跡する。sourceの分類や作者名をruntime構造に使わない。詳細な知識は一段のreferenceへ分け、`SKILL.md` は発火後に必要なprocedureと打ち切り条件だけを持つ。
