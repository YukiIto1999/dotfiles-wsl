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

- local: `bug-analysis`、`code-design`、`code-reviewer`、`commit-writing`、`change-writing`、`comment-writing`、`dependency-analysis`、`description-writing`、`documentation-writing`、`domain-modeling`、`error-design`、`grill-with-docs`、`grilling`、`impact-analysis`、`interface-design`、`ja-writing`、`module-design`、`performance-analysis`、`refactoring`、`tdd`、`web-research`
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
| review | `code-review`、`architecture-review`、`test-review`、`interface-review`、`naming-review`、`ui-review`、`browser-review` |
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

`code-design` は module 内部の型、関数、変換、純粋核と effect、抽象、局所性を決める。UI module内のmodule-privateなcomponent tree、props、state owner、composition、既存primitiveのreuseも同じ責務に含める。`module-design` は actor、change driver、責務、所有、境界、依存方向を決める。`interface-design` は確定済みの境界に、exact type、failure、side effect、ordering、互換性を持つconsumer-visible contractを与える。`architecture-design` は system 全体の topology、quality attribute、deployment、integration を決める。

`error-design`は、固定済みのmodule境界、責務owner、公開failure contractを入力に、owner内部のfailure表現、翻訳点、伝播、回復、集約、観測を決める。公開error shape、module間の責務配置、障害原因、reliability target、実装は所有しない。

`module-design`は、確定済みのactor、domain ownership、state、artifact lifecycle、system topologyを制約として消費する。module内部の実装、exact interface、serviceやrepositoryのtopology、domain語彙、既存構造のseverity付きreviewは所有しない。

`data-modeling`候補は、確定済みのdomainの意味を、正準形、valid state、lifecycle、serializationへ写す。`db-design`候補は、代表workloadから物理schema、constraint、access path、transaction、保存と復旧の受入条件を決める。既存databaseの監査は独立Skillにせず、対象engineの一次資料と既存review手段を使う。sourceからtargetへの移行手順は`migration`へ渡す。

`test-design` は risk、contract、oracle、test level、fidelity を決める。`tdd` は確定済みのbehaviorを一つのobservableな縦のsliceにし、意味のあるRED、最小GREEN、触れた範囲のREFACTORを反復する。原因未確定の障害、test suiteの監査、独立した構造変更は所有しない。

`refactoring` は保存するobservableと構造上の痛みを先に固定し、既存の安全網か必要最小限のcharacterizationを使って、一つの可逆な内部変更ずつ検証する。新しいbehavior、public contract、architecture、migrationは所有しない。TDD中の局所REFACTORは`tdd`に残す。

`prototype`候補は、設計や実装を止める一つの経験的な問いを、隔離した使い捨ての実行可能物で判定する。基礎モデルとの差を確認できなかったため配備しない。

`migration`候補は、承認済みのsourceからtargetへ、共存条件、各段の正本、変換、進行と撤退のgate、不可逆点後のrecovery、旧経路の除去を扱う。現時点では基礎モデルと既存Skillで不足を確認できていないため実装しない。

ここに境界を書いていない候補は、名前だけを仮置きした調査対象である。Job、trigger、判断所有権、根拠、完了条件、非責務を定めるまで実装しない。

## Donor の扱い

独自Skillは、モデルが一から作った規則を正本にしない。donorの一次本文から、具体的なprocedure、failure mode、trade-off、counterexampleを抽出し、[`architecture-standard`](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) とこのrepositoryの制約に合わせて再構成する。donor不在か改善未確認の規則は、原則としてruntime Skillへ入れない。

| Donor | 主に補強する候補 |
|---|---|
| [Matt Pocock skills](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df) | `bug-analysis`、`dependency-analysis`、`domain-modeling`、`code-design`、`module-design`、`code-review`、`tdd`、`prototype`、`web-research` |
| [Addy Osmani agent-skills](https://github.com/addyosmani/agent-skills/tree/be42637c5af93fdc8526b68ec2f2651b930f316c) | `impact-analysis`、`interface-design`、`code-review`、`tdd`、`bug-analysis`、`ui-design`、`performance-analysis`、security plugin |
| [WondelAI skills](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966) | `impact-analysis`、`refactoring`、`module-design`、`architecture-design`、`architecture-review`、`db-design`、`ui-review` |
| [dotnet skills](https://github.com/dotnet/skills/tree/7953ba85365219dc7df5d73634e1f9d0bfabf0b9) | `skill-creator`、`test-design`、`test-review`、`tdd` |
| [Vercel agent skills](https://github.com/vercel-labs/agent-skills/tree/b8caa260a420a73042e35521de4b5c8baf6446cc) | `component-design`、`performance-analysis`、`ui-review` |
| [Anthropic skills](https://github.com/anthropics/skills/tree/f17010c9bb483898c1d9c9f42dde2b3a98889434) | `skill-creator`、`ui-design`、`browser-review`、`description-writing` |
| [OpenAI Skills guidance](https://openai.com/academy/skills/) | `skill-creator`、routing評価、MCPを含むworkflow packaging |
| [PlanetScale database skills](https://github.com/planetscale/database-skills/tree/af0ce0cfb65cca4cc21d18ca0d9cf270ca99d488) | `db-design`、database監査、`migration` |
| [Supabase agent skills](https://github.com/supabase/agent-skills/tree/v0.1.8) | `db-design`、database監査、security plugin、`migration` |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | `code-design`、`module-design`、`refactoring`、`code-review`、`skill-creator` |
| [decomplect](https://github.com/shanev/skills/tree/8fd6aaf4d16e9c1e6caa5bfd9ba8d3bb52864c7f/decomplect)、Clairvoyance | `dependency-analysis`、`module-design`、`architecture-design`、`architecture-review`。Clairvoyanceは採用前にsourceを固定する |
| [effect-fp-skill](https://github.com/mikezupper/effect-fp-skill) | `code-design`、`data-modeling`、`error-design`。Effect固有APIは汎用規則にしない |
| [Hallmark](https://github.com/Nutlope/Hallmark)、[Impeccable](https://github.com/pbakaus/impeccable) | `ui-design`、`ui-review` |
| [japanese-tech-writing](https://gist.github.com/k16shikano/fd287c3133457c4fd8f5601d34aa817d)、[stop-ai-slop-jp](https://github.com/iKora128/stop-ai-slop-jp)、[slop-nuki](https://github.com/chezou/slop-nuki) | `ja-writing` |
| [code-humanizer](https://github.com/LeonardNJU/code-humanizer)、[deai-code](https://github.com/golovatskygroup/deai-code) | 品質判断だけを `code-review` に使い、著者推定を除く |
| [differential-review](https://github.com/trailofbits/skills/tree/main/plugins/differential-review) | security plugin |
| [Speakeasy writing-openapi-specs](https://github.com/speakeasy-api/skills/tree/d2eab5991ef881b39a26ab47432cf273c2c1abb5/skills/writing-openapi-specs) | raw OpenAPIを扱う場合の `interface-design`、`interface-review` reference |

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

### tddで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [architecture-standard implementation process](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/process/implementation.md)、[test methods](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/structure/tests/methods.md) | repository rootに表示なし | actorとuse caseからwork unitを定めること、test listを一つの縦のsliceずつ進めること、接続済みの型だけをREDに数えること、性質に合う最も内側の決定的なverifier、GREEN中の局所refactoring | test technique全般、test strategy、commitの分割をTDDが所有すること |
| [Matt Pocock tdd](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/tdd/SKILL.md) | MIT | public interfaceからbehaviorを検査すること、実装へ結合したtestとproduction計算を複製するoracleを避けること、REDを実測して一つの縦のsliceを実装すること | seamごとに利用者確認を必須にすること、refactoringをTDDのloopからすべて外すこと |
| [Addy Osmani test-driven-development](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/test-driven-development/SKILL.md) | MIT | repositoryのtest toolと規約を先に読むこと、REDの理由を確認すること、最小GREEN、GREEN中のREFACTOR、同じ成功済みcheckを無変更で繰り返さないこと | 固定のtest pyramid、全変更への一律発火、無条件のfull suite、test設計とbrowser検証の所有 |

`tdd`は、既に意味と期待結果が決まったbehaviorを実装する規律だけを所有する。testを大量に先行作成せず、consumerが観測する一つのsliceについて、production変更前のRED、最小GREEN、触れた範囲のREFACTORを完結させる。testの種類を選ぶ一般論、既存suiteの評価、原因分析、独立したrefactoringは別の仕事である。

代表scenarioは [`agents/fixtures/tdd-skill.json`](../../agents/fixtures/tdd-skill.json) に置く。baselineでは、agent resource reaperの`dryRun`について、削除対象の意味、公開option、package、Shell fixtureまで広く調べられた。一方、contract projectionの複数checkをまとめてREDにした後、全ledger、lock、worktreeのbehavior fixtureを一括で作る順序だった。

未見のdoctor JSON変更へSkillを適用すると、依頼上は新規に見えた`--json`が既に存在し、`status`の値域は未確定だと確認した。最初のsliceを`schemaVersion: 1`の公開だけに絞り、既存runtime checkの欠落をRED、report literalへの一項目追加を最小GREENとし、text出力、終了status、check順序は後続へ残した。全featureを先にtest設計せず、推測を加えずに一つのpublic observableへ収束したため、baselineで不足したslice分離とrestraintは改善した。forward evalでは編集とbuildを行っていない。

続けて隔離したCLI fixtureへ適用した。JSON全体を比較するtestを先に作り、`bash .tdd-eval/test-json.sh`は`schemaVersion`欠落を理由にexit 1となった。JSON literalへ`schemaVersion: 1`だけを追加すると、同じcommandがexit 0になった。整理すべき重複はなく、REFACTORと追加検証を増やさなかった。fixtureは評価後に削除した。

### refactoringで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [WondelAI working-with-legacy-code](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966/working-with-legacy-code) | MIT | change pointとtest pointの分離、現在behaviorのcharacterization、安全網の後で構造変更とbehavior変更を分けること | Sprout、Wrap、dependency breakingを通常のrefactoringへ常用すること、書籍由来の固定workflow |
| [Addy Osmani code-simplification](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/code-simplification/SKILL.md) | MIT | outputだけでなくerror、side effect、orderingも保存すること、既存規約を読むこと、一変更ごとの検証、触れた範囲への限定 | 行数、nesting、function sizeの固定閾値、無条件のfull suite、PR分割の固定 |
| [architecture-standard refactoring](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/process/refactoring.md) | repository rootに表示なし | safety netが足りない場合のcharacterization、境界ごとのcheckpoint、testと参照追跡、契機になった痛みが消えた時点で止めること | 各段で全testを実行すること、一括rewriteとしての内部書き直し |
| [dotnet testability-obstacle](https://github.com/dotnet/skills/blob/7953ba85365219dc7df5d73634e1f9d0bfabf0b9/plugins/dotnet-test/skills/testability-obstacle/SKILL.md) | MIT | 既存seamの再利用、必要memberだけの最小抽象、public signatureとdefault wiringの保存、seam自体とbehaviorの別検証 | C#固有の`TimeProvider`、`AsyncLocal`、process-global mutable seam |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | MIT | 新しい所有物の前に、削除、標準機能、既存mechanism、既存dependencyで足りるかを問う変換選択のlens | 全coding taskへの強制、最短diffと最少fileの最適化、一実装interfaceの一律削除、reviewとauditのworkflow |

`refactoring`は、保存対象を選び、現在のbehaviorを観測できる安全網を成立させた後、一つの内部構造変更ずつ同じ証拠で検証する。line countの削減や新しい抽象は成果ではない。Matt Pocockの`improve-codebase-architecture`は新しいmodule構成を選ぶため、`architecture-design`側のdonorとして残し、このSkillへは統合しない。

代表scenarioは [`agents/fixtures/refactoring-skill.json`](../../agents/fixtures/refactoring-skill.json) に置く。baselineでは、cleanupのproductionとcontract checkに重複した計算を共有する依頼に対し、自己参照oracleの危険を認識し、固定fixtureを追加する案まで出せた。一方、既存の小さい`home-backup-root.nix`も置換する広いhelperを最初から設計し、変更前のfocused checkと一段ごとのcheckpointを置かず、最後にrepository全体のcheckを予定した。新しいSkillは、意図的な独立計算かを先に問い、共有する場合もoracleの独立性を保ち、既存mechanismを残せる最小の一段から進める。

隔離fixtureのforward evalでは、public outputと例外を固定する既存2 testを変更前に実行し、exit 0を確認した。testを増やさず、重複したtrimと空名検証だけを一つの内部helperへ抽出し、同じcommandが2 test通過のexit 0を維持した。表示名とslugの異なる変換は統合せず、追加refactoringを行わなかった。fixtureは評価後に削除した。

baselineと同型の別fixtureでは、productionの二つの関数とcontract testが同じpath正規化を持つ共有依頼へ適用した。変更前にfixture内で`python -m unittest -v`を実行し、1 test通過のexit 0を確認した。production内だけを`_normalize_destinations`へ抽出し、testの独立計算はoracleとして残した。同じcommandが1 test通過のexit 0を維持し、test fileは変更しなかった。fixtureは評価後に削除した。

### prototypeをSkill化しない判断

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock prototype](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/prototype) | MIT | 一つの質問、最小の実行可能物、observableの可視化、反証例、本番永続化の回避、判断の記録 | 単一HTML、URL parameter式UI、UI variationを3案既定・5案上限とすること、prototype codeを条件付きで本番へ昇格すること |
| [Addy Osmani doubt-driven-development、source-driven-development](https://github.com/addyosmani/agent-skills/tree/be42637c5af93fdc8526b68ec2f2651b930f316c/skills) | MIT | 明示した主張、最小artifact、反証、判定分類、停止条件、版依存の外部仕様を先に確認すること | 全判断での別model review、三cycle固定、すべてのframework判断への引用要求 |
| [architecture-standard design process、evolution](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | 観測事実と解釈の分離、完了条件とrollback条件、可逆な小段階、不可逆判断の延期 | 本番変更用の手順や構造をprototypeへ持ち込むこと |
| [WondelAI pragmatic-programmer](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966/pragmatic-programmer) | MIT | 残す本番品質のtracer bulletと、知識を得て捨てるprototypeの区別 | correctness、test、edge caseを一律に無視すること |

候補の責務は、文書や既存codeから確定できない一つの経験的な不確実性を、隔離した使い捨ての実行可能物で判定することとした。成果はcodeではなく、環境、版、raw observation、`支持 / 反証 / 判定不能`、判断への含意である。本番codeへ残す縦slice、性能bottleneckの診断、障害原因の分析、migration rehearsalは所有しない。

最初のforward evalは、transient user serviceの終了statusを調べたが、user busが存在せず判定不能で終わった。別のfresh-session比較では、`flock`中のfileを`mv`で置換した後もpathnameの排他が保たれるかを実測した。baselineと候補ありの両方が、支持条件と反証条件を先に定め、旧inodeと新inode、二番目のlock取得statusを一回の隔離実験で観測し、pathnameの置換後は排他を維持できないと同じ結論へ到達した。両方とも一時資源を回収し、別のlock実験へ範囲を広げなかった。独立Skillによる改善がないため、donorは判断材料として残し、runtime Skillは追加しない。

### migrationをSkill化しない判断

| Donor | License | 利用できる知見 | 汎用化しない内容 |
|---|---|---|---|
| [Addy Osmani deprecation-and-migration](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/deprecation-and-migration/SKILL.md) | MIT | consumer別のtouchpoint、additiveな準備、backfill、read切替、旧usage確認後の削除 | 全migrationへのdown path強制、固定の責任分担、観測不能なconsumerも含む厳密なusage zero |
| [WondelAI release-it](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966/release-it) | MIT | deployとreleaseの分離、新旧版の互換確認、段階gateごとの観測 | canaryやblue-greenの選択、traffic率、観測時間、rollback時間の固定値 |
| [PlanetScale database-skills](https://github.com/planetscale/database-skills/tree/af0ce0cfb65cca4cc21d18ca0d9cf270ca99d488/skills) | MIT | engineと版ごとのlock、algorithm、replica lag、throttle、cutover延期、cancelとretryの確認 | `LOCK=NONE`、Vitess strategy、PlanetScale deploy request、特定toolの優先 |
| [Supabase agent-skills v0.1.8](https://github.com/supabase/agent-skills/tree/8331f910845103c08d51f6ca1d86ebb7d1f745e3) | MIT | 既存projectのschema管理方式を先に確認し、試行中はmigration historyを汚さず、確定後にreview可能なartifactを作ること | Supabase CLI、MCP、advisor、固定batch件数とtimeout |
| [architecture-standard migration](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/process/migration.md) | repository rootに表示なし | mutable stateの並行移送におけるsnapshot、watermark、record version、final drain、write fence、正本切替 | 全migrationのforward-only化、outbox、checksum、三段階の一律要求 |

外部資料には共通する有用な知見があるが、固有のprocedureはdata store、並行更新、停止許容、consumer更新方法によって変わる。Addyのdown migration必須とarchitecture-standardのforward-onlyは両立せず、共通化できるのは不可逆点の前後で実行可能なrecoveryを選ぶことまでである。rollback、roll-forward、restore、replay、compensationのどれを使うかは対象から決める。

baselineでは、session ledger v1の`owner_start_time`をv2の`owner_process_start`へ改名し、rebuild前後のagentが共存するscenarioを使った。詳細を列挙した依頼と、目的だけを示した自然な依頼の双方で、現行のexact-key validatorと全ledger preflightから、v1/v2 dual-readerとv1 writerを先に配備し、旧reader排除後にv2 writerと再実行可能な変換へ進む計画を導けた。別schemaであるruntime cache metadataを除外し、bridge generationをrollback先にし、`updated_at`を持たないledgerのmtimeをretention基準として保存する点までrepository evidenceから特定できた。

Skillなしでもsource、target、consumer、正本、共存、cutover、recovery、cleanupを具体化でき、誘導を減らした同一scenarioでも不足を観測できなかった。現状は`impact-analysis`がconsumerと共存条件を渡し、対象固有の設計と`tdd`がcompatibility codeとtransformerを実装すれば足りる。反復する失敗が観測されるまで、donorは調査記録に留め、runtime Skillとrouting costを増やさない。

### naming-reviewをSkill化しない判断

| Donor | License | 利用できる知見 | 汎用化しない内容 |
|---|---|---|---|
| [architecture-standard naming](https://github.com/YukiIto1999/architecture-standard/blob/88d7317dd5054e09f003f0bdca34295e158b40de/principles/naming.md) | repository rootに表示なし | 同じ概念と別概念の語彙、型と単位、参照範囲、code、schema、DB、UI、文書の横断確認 | 英語、boolean prefix、collection複数形、略語禁止の一律適用 |
| [Matt Pocock domain-modeling、codebase-design、code-review](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering) | MIT | glossary参照と語彙決定の分離、repository規約の優先、規約違反と意味矛盾の根拠を分けること | glossary更新、ADR、module taxonomy、diff全体のreview |
| [Addy Osmani code-review-and-quality、api-and-interface-design](https://github.com/addyosmani/agent-skills/tree/be42637c5af93fdc8526b68ec2f2651b930f316c/skills) | MIT | 公開名をobservable contractとして扱い、misleading nameを表面的な統一より優先すること | REST URL、field casing、boolean prefix、enum形式の固定 |
| [dotnet skills](https://github.com/dotnet/skills/tree/7953ba85365219dc7df5d73634e1f9d0bfabf0b9) | MIT | 外部規約より既存projectのnaming familyを先に確認し、成果物の役割を同種peerと比べること | DTO suffix、interface prefix、folder、class shape、casingの固定 |

候補の責務は、確定済みの意味、役割、単位、粒度、scope、context内の語彙に対し、既存名の不一致を根拠付きfindingへまとめることに限定した。正式語が未確定なら`domain-modeling`、rename実装は`refactoring`、diff全体の判定は`code-reviewer`が所有する。

baselineでは、Account、Member、Membership、Invoice、minor unit、UTC instant、boolean predicateを定義し、API、DB、type、function、fieldの命名だけを監査した。Skillなしでも、MembershipをUserやAccountとして表す役割不一致、AccountとOrganizationの語彙分裂、金額の単位とowner、Dateとinstant、Statusとpredicate、Atとdurationの矛盾を、語彙を新規決定せず六つの根本findingへまとめられた。独立methodologyによる改善を観測できないため、現時点ではrepository規約と基礎モデルで足りる。

### test-designをSkill化しない判断

| Donor | License | 利用できる知見 | 汎用化しない内容 |
|---|---|---|---|
| [architecture-standard tests](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de/structure/tests) | repository rootに表示なし | propertyからobservable、oracle、最内側の十分な手段を選び、同じpropertyを重複検査しないこと | 固定pyramid、directory、runner、coverage、mutation、MC/DCの一律threshold |
| [dotnet test skills](https://github.com/dotnet/skills/tree/7953ba85365219dc7df5d73634e1f9d0bfabf0b9/plugins/dotnet-test/skills) | MIT | fault modelからtest obligationを導き、ambient operationとtestability obstacleを特定すること | C#固有seam、A–F grade、test行数、sourceとtest fileの静的pairing |
| [Matt Pocock tdd](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/tdd) | MIT | callerが観測するbehavior、SUTと独立したliteralやspecのoracle、内部interactionよりstateとoutcomeを優先すること | public APIだけへの限定、seamごとの確認停止、mockやtest DBの固定判断 |
| [Addy Osmani test-driven-development](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/test-driven-development/SKILL.md) | MIT | repositoryのtest規約、resourceによるfidelity、time、order、shared stateの制御 | 80/15/5 pyramid、realを常に優先する順位、全behavior変更への自動発火 |
| [Anthropic webapp-testing](https://github.com/anthropics/skills/tree/f17010c9bb483898c1d9c9f42dde2b3a98889434/skills/webapp-testing) | Apache-2.0 | static HTMLとrender後stateの区別、action前のreadiness predicate | Python Playwright、headless Chromium、`networkidle`、固定timeout、実行workflow |

候補の責務は、確定済みbehaviorとriskを、observable、独立oracle、seamとtest level、必要なfidelity、data、fault、concurrency、決定性、residual riskへ変換することに限定した。test実装は`tdd`、既存suiteのfindingは`test-review`が所有する。browser実行は証拠取得の手段であり、独立した判断責務にはしない。

baselineでは、agent bundleのatomic publish transactionについて、consumerが完全な旧releaseか新releaseだけを見る契約を入力にした。Skillなしでも、本番validatorと独立したtree manifest oracleを選び、実process、Linux filesystem、`flock`、本番rename helperを使うbehavior testへ絞れた。crash前後、並行installer、同一release再実行の四caseを同期markerで制御し、unlinkとsymlinkの二段切替、未完成releaseの公開、lock除去、manifest比較除去のmutationがどのcaseで検出されるかまで対応付けた。kernel crash、電源断、consumer側の複数回path解決などのresidual riskも分離できたため、独立Skillによる改善を確認できない。

### data-modelingをSkill化しない判断

| Donor | License | 利用できる知見 | 汎用化しない内容 |
|---|---|---|---|
| [architecture-standard data、type、separation](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | 正準形、valid state、正本と互換表現の分離、事実と現在値の区別 | 全dataのevent化、固定layer、DSL |
| [Matt Pocock domain-modeling](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/domain-modeling) | MIT | 具体scenarioと反例、確定済みと未決定の分離 | 文書配置、domainの意味とdata表現の二重所有 |
| [effect-fp-skill domain-types](https://github.com/mikezupper/effect-fp-skill/blob/e3ee107dc4e8a301fbddea43e85d4d1404fa15fc/references/domain-types.md) | CC BY 4.0 | parse後の正準形、状態固有data、wire表現との変換 | Effect、TypeScript、Schema、brand、Optionの強制 |
| [WondelAI DDIA、DDD、Pragmatic Programmer](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966) | MIT | identityとvalue、導出可能なdata、event sourcingの適用条件 | score、固定taxonomy、UUIDやevent sourcingの一律採用 |

候補の責務は、domainの意味、owner、不変条件、lifecycleが確定した後に、identity、正準形、状態固有data、absence、時刻、導出値、serializationとreader、writer互換性を決めることに限定した。公開contractは`interface-design`、private typeとfunctionは`code-design`、物理schemaは`db-design`が所有する。

baselineでは、agent resourceのsessionとworktree ledgerを対象にした。Skillなしでも、session ownerを`(boot_id, owner_pid, owner_start_time)`、worktree identityを正準化済み`(common_dir, path)`、filename hashとdevice、inodeを別の導出値と実体証明に分けられた。既存fieldだけで状態別の必須data、正準遷移、terminal state、`updated_at`とmtimeの互換、v1 exact-key reader、未知dataのfail-closedまで設計し、event log、generic envelope、新versionを棄却した。さらに、診断値である`last_reason`が`quarantine-remove-root-unresolved`だけ回復分岐を兼ね、`status`だけではvalid stateが定まらない混在も特定できた。独立methodologyによる改善余地を観測できないため、現時点では基礎モデルと既存設計Skillの境界で足りる。

### db-designをSkill化しない判断

| Donor | License | 利用できる知見 | 汎用化しない内容 |
|---|---|---|---|
| [PlanetScale database-skills](https://github.com/planetscale/database-skills/tree/af0ce0cfb65cca4cc21d18ca0d9cf270ca99d488) | MIT | exact queryからのindex設計、read、write、storage cost、実planと代表負荷による確認、engine別のDDL lockとrestore | 固定型、`LOCK=NONE`、Vitess固有workflow、固定retention |
| [Supabase agent-skills v0.1.8](https://github.com/supabase/agent-skills/tree/8331f910845103c08d51f6ca1d86ebb7d1f745e3) | MIT | keyの範囲、局所性、分散生成のtrade-off、predicateとprojectionに対応するindex、短いtransactionと一定のlock順序 | PostgreSQL固有の既定、RLS、CLI、固定batch値 |
| [WondelAI DDIA、DDD](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966) | MIT | access pattern、skew、consistencyからのstorage設計、阻止するanomalyからのisolation選択、代表dataと並行性による計測 | score、固定taxonomy、UUID、B-tree、polyglot persistenceの一律採用 |
| [architecture-standard data、storage、migration](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | logicalとphysicalの分離、constraintとwrite path、再生成可能な派生copy、同条件での計測、不可逆点に応じたrecovery | 全relationへのFK、永久保存、単一store、outbox、forward-onlyの一律要求 |

候補の責務は、確定済みの論理data model、owner、不変条件、lifecycle、engineと代表workloadから、物理schema、型、key、constraint、access path、index、transaction、isolation、retention、capacity、backupとrestoreを選ぶことに限定した。公開queryは`interface-design`、発生中のbottleneckは`performance-analysis`、backfillとcutoverの順序は`migration`が所有する。既存schemaのfindingは対象engineの一次資料を使う監査で扱い、独立Skillにはしない。

baselineでは、`tec-lane-buyer-cart`のcart ledgerを対象にし、既存migrationを見ずにADR、port、store、integration specificationから設計した。Skillなしでも、買い手単位のsettlement、settled lines、再構築可能なcurrent projectionという三relation、複合key、同一台帳内FK、最小index、一確定一transaction、履歴保持、projection再構築とPITRを導けた。これは同repositoryの`deploy/database/up/0039_cart_selections.sql`にある主要構造と一致した。さらに、`ordinal`と`line_id`の一意性、空白型番、append-only、`max(version) + 1`の並行更新という既存設計の未強制条件も分離できた。独立methodologyによる改善を観測できないため、donorは判断材料として残し、runtime Skillは追加しない。

### database-reviewをSkill化しない判断

既存databaseの監査では、domain invariant、DDL、全write path、transaction、test、engine仕様を対応付ける。PlanetScaleとSupabaseの資料はengine固有のconstraint、index、lock、RLS、rolloutを補うが、独立したreview procedureを与えない。

baselineではPostgreSQLのaudit ledgerを監査し、親rowの更新と削除だけを拒否しても、任意の子rowを後から追加でき、`TRUNCATE`がrow triggerを通らないためimmutabilityが閉じない問題を特定できた。既存のreview能力とengine一次資料で実害のあるfindingまで到達しており、Skill固有の改善を観測していない。反復してisolation anomaly、workload、restoreの欠落を見逃す証拠が得られるまで追加しない。

### architecture-designをSkill化しない判断

| Donor | License | 利用できる知見 | 汎用化しない内容 |
|---|---|---|---|
| [architecture-standard design、separation、evolution](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | 事実、要件、境界、戦術の順序、actorとchange reason、可逆性、ADR | project固有技術、固定layer、全依存のinward化 |
| [Matt Pocock codebase-design、Design It Twice](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/codebase-design) | MIT | materially differentな案、同じconstraintでの比較、seam、locality、deletion test | 固定数の案、personaとsubagent、interfaceだけへの限定 |
| [WondelAI DDIA、Release It!](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966) | MIT | consistency、availability、latency、failure、integration、deployment、capacity、recoveryのtrade-off | score、特定store、saga、breaker、bulkhead、負荷倍率の一律採用 |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | MIT | 現状維持、新componentなし、既存mechanismを比較対象にすること | shortest diff、fewest files、常時発火 |

候補の責務は、確定済みの問題、domain ownership、外部contract、quality attribute、運用制約から、process、service、worker、store、queue、external systemのtopology、dataとcontrol flow、runtime、deployment、failure、trustの境界を比較することとした。moduleの責務は`module-design`、exact contractは`interface-design`、未確認のruntime特性は隔離実験や各analysis、既存構造のfindingは`architecture-review`が所有する。

baselineでは、self-hosted Web調査基盤を対象にし、実装を見ずに`agent client → gateway → SearXNG/Crawl4AI別front → 別backend container → 外部Web`を設計した。direct接続案と統合service案を棄却し、capability別のfailureとdeployment、loopback、credential境界、固定image、runtime probe、段階rolloutとgeneration rollbackまで既存構造と一致した。欠けた`web_url_read`拒否とdownstreamの`failOpen`は、選択済みgatewayへ与えるauthorizationとfailure contractのexact bindingである。system-level constraintを後続の`interface-design`とsecurityへ渡せばarchitecture判断は保存されるため、このscenarioから独立Skillの改善を確認できない。

### module-designで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock codebase-design](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/codebase-design) | MIT | 責務配置の異なる案、seamの位置とinterface内容の分離、同じ形式での比較、代表usageからのcaller burden確認 | 三案と複数subagentの固定、deep moduleの一律優先、既存testの削除 |
| [architecture-standard design、separation、dependency](https://github.com/YukiIto1999/architecture-standard/tree/88d7317dd5054e09f003f0bdca34295e158b40de) | repository rootに表示なし | actorとchange reason、隠す判断、state owner、source dependencyとruntime callの分離 | 固定layerとdirectory、全依存のinward化、port、DI、composition root、one-file-one-conceptの強制 |
| [Shane Vitarana decomplect](https://github.com/shanev/skills/tree/8fd6aaf4d16e9c1e6caa5bfd9ba8d3bb52864c7f/decomplect) | MIT | couplingのstrength、distance、volatility、ownership、shared stateとtemporal contractの実費 | functional coreの標準化、全依存のinversion、review finding形式 |
| [WondelAI software-design-philosophy、team-topologies](https://github.com/wondelai/skills/tree/6bac1534f9f256a56fc2b4dd0e70b9a692758966) | MIT | information hiding、change amplification、caller load、data、runtime、artifact ownership | deep moduleの一律優先、固定scoreとteam taxonomy、moduleとteamの一対一対応 |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | MIT | 新moduleなしと既存ownerを対照に置き、新境界がdistinct change driver、state、artifact lifecycle、ownershipを封じ込めるか問うこと | file数、diff、行数、標準libraryを常時優先すること、single implementation interfaceの一律否定 |

`module-design`は、actor、change driver、stateとartifact lifecycleを固定し、責務配置の異なる案をhard constraint、変更伝播、caller burden、runtime crossing、build、deploy、可逆性で比較する。moduleを増やすことも減らすことも目的にせず、同じ制約下で他案を支配する案か、優先するriskに対するtrade-offを選ぶ。

代表scenarioは [`agents/fixtures/module-design-skill.json`](../../agents/fixtures/module-design-skill.json) に置く。baselineでは、AgentMemory backendのnpm sourceとpackageをagent integrationへ移す案を正しく逆依存として棄却できた。一方、共通versionとupstream releaseを理由に、新しいvendor名のrepository rootへbackend、hook、plugin、MCP entrypointを集約する案を推奨した。現行のcontainer ownerがbackend sourceとruntime stateを持ち、agent integrationとMCPが型付きcontractを消費する境界で足りるかを対照にせず、root ownershipとrelease contractを増やした。新しいSkillは、新moduleなしを候補に含め、独立したchange driver、state、artifact lifecycle、accountable ownerを封じ込めない境界を棄却する。

forward evalでは、Git identity templateと生成先のownerを実装から比較した。`accounts`所有、`toolchain/git`所有、新しい`identity` module、`sops`所有を同じ制約で比べ、Git構文とinclude pathを`toolchain/git`、identity値とsecret配備を`accounts`に残す現行案を選んだ。新moduleは独立consumer、state、artifact lifecycleを持たずcontractを一段増やすとして棄却した。依頼されていないADR形式まで生成したため、成果に必要な判断だけを返し、文書形式を発明しない停止条件を追加した。

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

代表scenarioは [`agents/fixtures/interface-design-skill.json`](../../agents/fixtures/interface-design-skill.json) に置く。baselineでは、AgentMemoryの`upstream.root`を狭めるため、hook entrypointとplugin pathを型付きfieldへ変換できた。一方、既存のservice contractが既に持つURLとunitを新しい`runtime` optionへ複製し、一致assertionで正本を二つにした。上流が定義していないHTTP API contractをpackage versionから作り、backendとMCPのlockstep更新も要求した。新しいSkillは、既存正本の再利用、semantic contractとreleaseの分離、consumer usageから必要なsurfaceだけを導く手順を補う。

forward evalでは、agent ownerのCodex executableをMCP側へmirrorし、一致assertionを置く提案を検討した。既存の`dotfiles.agents.clientExecutables.codex`がabsolute path、read-only、internal、defaultなしのexact contractを既に持ち、MCPはそこへ引数だけ加えると確認した。mirrorはsource dependencyを消さず、同じ意味のreaderと将来の削除コストを増やすため、新しいinterfaceを作らない案を選んだ。依頼なしにADR形式で回答したため、結果を推薦、contract、compatibility、verification obligationへ限定する出力規則を追加した。

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

代表scenarioは [`agents/fixtures/code-design-skill.json`](../../agents/fixtures/code-design-skill.json) に置く。baselineでは、doctorの重複ID、安定順序、summaryを一つのjq finalizerへ置く判断はできた。一方、既存の五配列を使えば足りる内部処理へ、observation envelope、JSONL file、record関数、source用main guardを追加し、数値scoreで案を選んだ。新しいSkillは、既存表現と直接実装を対照にし、pure/effect分離やprivate abstractionを具体的な変更costで正当化する手順を補う。

forward evalでは、AgentMemoryの全hookに共通URL、二つのhookにだけ固有の定数環境を渡す内部構造を設計した。既存`hookNames`を正本に保ち、完全なspec一覧や汎用wrapper builderを棄却し、疎な例外mapを選べた。一方、閉じた定数をshell行へ変換する専用rendererを追加したため、escaping責任だけを増やすhelperを棄却し、既存literalかnative builderを優先する規則を追加した。

### component-designを独立Skillにしない判断

| Donor | License | 利用できる知見 | 固定規則にしない内容 |
|---|---|---|---|
| [Vercel composition patterns](https://github.com/vercel-labs/agent-skills/tree/b8caa260a420a73042e35521de4b5c8baf6446cc/skills/composition-patterns) | 対象SkillはMIT。repository rootに表示なし | behaviorを選ぶflagの組合せを明示variantやcompositionにすること、協調partsだけがstate contractを共有すること | compound component、provider、context、React APIの一律採用 |
| [Addy Osmani frontend-ui-engineering](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/frontend-ui-engineering/SKILL.md) | MIT | design systemと隣接patternの確認、state scopeに応じたlocal、lifted、contextの選択 | 200行threshold、固定file tree、container/presenter、prop階層の数値基準 |
| [Feature-Sliced Design](https://github.com/feature-sliced/documentation/tree/1d371daf8abf722779b0fd30a4bcf3b6b292e752) | MIT | use-caseによる局所化、page固有UIを無理に抽出しないこと、shared primitiveから業務policyを除くこと | 固定layer、segment名、barrel、same-layer規則の輸入 |
| [Matt Pocock codebase-design](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/codebase-design) | MIT | deletion test、change locality、callerへ漏れる知識による抽出判断 | component固有taxonomy、固定数の案とsubagent |

候補の責務は、確定済みのfeature、画面state、module境界、design systemから、module-privateなcomponent tree、state owner、props、event、slotを決めることとした。これはmodule内部の構造を決める`code-design`と同じtrigger、入力、判断所有権を持つ。別Skillにすると同じ設計を二重所有するため、既存componentの確認とfeature-localな直接案を`code-design`へ統合した。shared ownerへの昇格は`module-design`、外部公開するcomponent APIは`interface-design`が所有する。

baselineでは、`tec-lane-buyer-cart`のbuyer cart画面を、既存component実装を見ずに設計した。Skillなしでも、pageをremote stateとmutationのownerにし、widgetをport非依存に保ち、業務判定をentity modelへ残し、local stateの複製を避けられた。一方、既存の`Split`、`Facts`、`Table`、`Row`、`Cell`、`Badge`を設計前に確認せず、独立stateも再利用理由もない局所componentを分けた。この不足は`code-design`が既に持つ隣接実装と既存mechanismの確認で防げる。component固有の独立methodologyによる改善ではないため、新しいSkillを追加しない。

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

代表scenarioは [`agents/fixtures/error-design-skill.json`](../../agents/fixtures/error-design-skill.json) に置く。baselineでは、agent resourceのvalidation、filesystem、lock、proc identity、race、cleanupを分類し、global trust failureとrecord単位のpreserveを分けられた。一方、Bashの既存status、ledger reason、stderrで必要な意味を表せるかを確認せず、全経路へ汎用Resultとboundary translatorを導入した。新しいSkillは、callerの扱い、回復、公開mappingが異なるfailureだけを区別し、既存表現を保つ案から比較する手順を補う。

forward evalでは、doctorの公開JSON、exit status、observation境界を固定し、missing tool、非zero、malformed output、semantic mismatch、caller cancellation、cleanupを設計した。既存statusと固定failure recordを保ち、独立observationは集約し、runner invariantの破壊とcaller cancellationだけを停止条件にできた。原因別enum、Result、retry、追加logは棄却した。一方、caller cancellationとobservation deadline、代替成功と保守的failure mappingを混同し、raw causeを無条件に保持できる記述が露出したため、contractとconsumerの有無から扱いを決めるよう本文を限定した。

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
