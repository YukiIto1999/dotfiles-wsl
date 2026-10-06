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

外部Skillは原名のIDで固定sourceを直接採用し、本文、reference、script、frontmatterの起動flagを書き換えない。
custom Skillの実行手順とreferenceは自立させ、donorの作者名や「原版に従う」という実行linkを持たせない。
独立した専門仕事が必要な条件では、別Skillを実際に順次実行して証拠を受け渡す。
供給元と依存metadataを選ぶowner、登録条件、差替手順は[外部リポジトリ所有Skillの構成](repository-skills.md)にまとめる。

Codexに同梱されるsystem `skill-creator`は、[`skills.config`](https://developers.openai.com/codex/config-reference#skillsconfig)で無効化し、localの`skill-design`だけをrouting対象にする。ClaudeとOpenCodeでも同等のローカル正本を使う。

```sh
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.skills.enabled
```

有効なSkillは[`skills/module.nix`](../../skills/module.nix)が、選択したCapabilityとSkill間依存を満たすregistry entryから導く。`dotfiles.skills.enabled`はread-onlyの内部派生値であり、Agent clientはこの有効集合だけを各client形式へ投影する。

MCP専用の薄いwrapperは置かない。`repository-research`は探索経路とsource検証、`browser-operation`は実surfaceの状態遷移と副作用境界、`github-operations`はidentity、pre-read、idempotency、不可逆操作、`memory`はrecallの検証、保存admission、privacy、failure fallbackを所有する。SkillとCapabilityの対応、subagentごとのrouteは[`agents/subagents/routing.nix`](../../agents/subagents/routing.nix)を正本にする。

## 直接採用

固定revisionの正本は[`flake.nix`](../../flake.nix)と[`flake.lock`](../../flake.lock)、採用IDとdirectory pathの正本は[`skills/plugins/module.nix`](../../skills/plugins/module.nix)である。
Orcaの操作Skillとarchitecture-standardの運用Skillに加え、次の固定sourceから個別Skillを採用する。
sourceはrepository全体を保持し、rootのlicenseと同梱資材を残したままSkill directoryを配備先から参照する。

| Source | Flake input | 固定revision | License |
|---|---|---|---|
| [Matt Pocock skills](https://github.com/mattpocock/skills/tree/4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d) | `mattSkills` | `4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d` | [MIT](https://github.com/mattpocock/skills/blob/4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d/LICENSE) |
| [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp/tree/cf2eab96d96cad3d47ce769b9638815d1775500f) | `chromeDevtoolsSkills` | `cf2eab96d96cad3d47ce769b9638815d1775500f` | [Apache-2.0](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/cf2eab96d96cad3d47ce769b9638815d1775500f/LICENSE) |
| [.NET skills](https://github.com/dotnet/skills/tree/0dcd43ceb15e15a2c45dd54075fbcf3a30632154) | `dotnetSkills` | `0dcd43ceb15e15a2c45dd54075fbcf3a30632154` | [MIT](https://github.com/dotnet/skills/blob/0dcd43ceb15e15a2c45dd54075fbcf3a30632154/LICENSE) |

次のpathは各固定sourceのrootからの相対pathであり、directoryの配置やSkill名をlocalの命名体系へ変換しない。

| ID | Source内のdirectory | 上流が所有する仕事 |
|---|---|---|
| `codebase-design` | Matt `skills/engineering/codebase-design` | deep module、interface、seam、testabilityの共通語彙と設計 |
| `diagnosing-bugs` | Matt `skills/engineering/diagnosing-bugs` | 障害と性能regressionのfeedback loop、再現、仮説、修正、regression test |
| `tdd` | Matt `skills/engineering/tdd` | 合意したpublic seamで、一つのtestと最小実装を進めるRED→GREEN |
| `domain-modeling` | Matt `skills/engineering/domain-modeling` | domain語彙を問い直し、`GLOSSARY.md`、context map、ADRへ確定事項を記録 |
| `grilling` | Matt `skills/productivity/grilling` | 明示的な依頼に対するdesign treeとfrontier単位の質問 |
| `code-review` | Matt `skills/engineering/code-review` | fixed pointから`HEAD`までのStandardsとSpecの並列review |
| `improve-codebase-architecture` | Matt `skills/engineering/improve-codebase-architecture` | deepening候補のHTML reportと、選んだ候補のgrilling |
| `setup-matt-pocock-skills` | Matt `skills/engineering/setup-matt-pocock-skills` | projectごとのissue trackerとdomain文書の利用設定 |
| `grill-with-docs` | Matt `skills/engineering/grill-with-docs` | `grilling`と`domain-modeling`を実行するstateful interview |
| `grill-me` | Matt `skills/productivity/grill-me` | `grilling`を実行するstateless interview |
| `to-spec` | Matt `skills/engineering/to-spec` | 確定した会話の仕様化、test seamの合意、trackerへの発行 |
| `to-tickets` | Matt `skills/engineering/to-tickets` | 承認したtracer-bullet ticketとblocking edgeの発行 |
| `prototype` | Matt `skills/engineering/prototype` | design questionへ答えるlogicまたはUIの実行可能な試作 |
| `retro` | Matt `skills/engineering/retro` | coding sessionの一次記録から環境改善案を提示 |
| `writing-for-agents` | Matt `skills/productivity/writing-for-agents` | agent文書のcontext pointer、情報階層、完了条件、削減 |
| `a11y-debugging` | Google `skills/a11y-debugging` | Lighthouse、semantics、keyboard、focus、target、contrastの実画面監査 |
| `debug-optimize-lcp` | Google `skills/debug-optimize-lcp` | traceからLCP subpart、element、requestを調べて比較 |
| `msbuild` | .NET `plugins/dotnet/skills/msbuild` | build failure、binlog、build性能、既存XMLとextension contract |
| `run-tests` | .NET `plugins/dotnet-test/skills/run-tests` | repositoryとSDK modeに一致するtest command、filter、report |
| `platform-detection` | .NET `plugins/dotnet-test/skills/platform-detection` | import precedenceからtest platformとframeworkを識別 |
| `filter-syntax` | .NET `plugins/dotnet-test/skills/filter-syntax` | filtered runでconsumerが読むreference-only helper |
| `microbenchmarking` | .NET `plugins/dotnet-diag/skills/microbenchmarking` | BenchmarkDotNetで実callerに対応する比較instrumentを設計・実行 |
| `nuget-trusted-publishing` | .NET `plugins/dotnet-advanced/skills/nuget-trusted-publishing` | nuget.orgのOIDC publishing設定とAPI key移行 |

## Routing

codingの共通設計は`codebase-design`、一般の故障とnative性能regressionは`diagnosing-bugs`、test-firstの実装は`tdd`を使う。
refactoringは確定したbehaviorとscopeを保つ実装作業とし、そのためだけの汎用Skillは置かない。
実装者とreviewerは、不要な処理を消せるか、既存owner、標準library、native機能、導入済みdependencyで要件を満たせるかを比較する。
短いdiffやline数の削減で要件、安全性、外部契約を弱めない。
rawのPonytailとMatt `research`は配備せず、その原則を既存workerと自立した`web-research`へ置く。

`diagnosing-bugs`はbrowserを使わないloopも成立するため、browser Capabilityへのhard依存を持たない。
browserが必要なbranchだけ、その環境で利用可能な専門Skillへ渡す。
`tdd`はtest seamへの事前合意を要求する。

`disable-model-invocation: true`を持つinterview、仕様化、ticket分割、retro、setup、architecture探索の原版は、利用者が明示的に呼ぶcommandとして使う。
`filter-syntax`はこれに加えて`user-invocable: false`を保ち、`run-tests`がplatformとframeworkを確定したfiltered runで必要とした場合だけ読む。
この二flagが両方あるhelperはenabled registryと依存closureには残すが、全clientのnamed Skill discovery directoryとsubagent routeから除外する。
registryの固定raw sourceは保持し、policy rosterが表示する絶対pathをconsumerが`Read`で開くため、native Skill起動toolによる名前解決に頼らない。
`run-tests`のsource実体からも元のsibling referenceへ到達でき、helper用alias、wrapper、本文の書換えは作らない。
片方のflagだけを持つ明示commandなどの投影は変更せず、原版のfrontmatterを各native clientへ渡す。

`code-review`の対象は`git diff <fixed-point>...HEAD`で得るcommitted rangeであり、任意のstaged/unstaged差分を読む旧local reviewではない。
`verified-committed-range`には解決したfixed pointと対象`HEAD`のcommit SHA、Specの所在、実行済み検証の証拠を含める。
上流`code-review`のworkflowはtop-level callerが所有し、commit範囲の確認、StandardsとSpecの並列委譲、二軸を分けた集計を行う。
native subagentは再帰的にsubagentを起動できないため、`reviewer`は原版のStandardsまたはSpecのbriefと根拠を受け取る、read-onlyの単一軸workerとする。
`reviewer`の`code-review` routeは必須workflowではなくdynamicな参照であり、自分では再委譲や軸間の統合、順位付けをしない。
対象projectのissue tracker設定がない場合は上流の`setup-matt-pocock-skills`を使うため、`code-review`のSkill依存にも登録する。
未commit差分をreview対象へ含めるために無断でcommitせず、別sessionが作業中のcheckoutでは`HEAD`を動かさない。
reviewerは目的をrequest、issue、specから固定し、全changed subsystemのbehaviorをcallerとtestまで追う。
testがgreenでも目的との因果関係がない変更を指摘し、unrelated cleanupを同じ修正へ混ぜない。
findingは発生条件、影響、最小のchanged rangeと根拠を持ち、指定したaxis内だけで返す。

`browser-operation`はPlaywrightの実経路verificationと副作用境界を持ち、browser-automationだけを要求する。
browser-diagnosticsの入口はcustom `browser-performance`、LCP専門の`debug-optimize-lcp`、実画面a11yの`a11y-debugging`とする。
Googleの固定sourceは配備するChrome DevTools MCP 1.10.1に対応し、必要なreferenceを切り離さない。
例の引数や値はsessionの実tool schemaで確認し、page IDを固定する。
Lighthouseや概算contrast snippetをWCAGの全合格判定にせず、lab traceをfield CWVに置き換えない。

[`heap-analysis`](../../skills/heap-analysis/skill/SKILL.md)はheap-diagnosticsだけを要求し、他Skillへのhard依存を持たない。
Chrome/Node.jsの同じworkloadと終了条件のlocal snapshotを比べ、snapshotごとのnode identity、dominator、複数のretainer pathと実装上の寿命から保持を説明する。
native .NET/RustのdumpやRSSだけの増加をJavaScript leakへ置き換えず、単独captureでは保持の事実と未確認の成長を分ける。
headerとresident stateを先に調べ、loadと重い解析を逐次実行し、不要なgraphをunloadする。
snapshotをproject-memoryへ送らず、任意host code実行toolや別provider直結で分析を代用しない。
providerは固定published `@memlab/mcp-server` `2.86.0`の解析・session入口だけを公開し、調査Git sourceのSHAからpackageのtoolやschemaを推測しない。

.NET Skillの依存は対象projectのSDK、runner、BenchmarkDotNetであり、常に必要でないbrowserやcloud Capabilityを登録しない。
識別だけの`platform-detection`とcommand・実行の`run-tests`を分け、後者が必要時に前者と`filter-syntax`を読む。
`run-tests`のwatch/hot reload branchは通常のone-shot実行へ広げず、未採用の`mtp-hot-reload`を提供済みと報告しない。
NuGet specialistはnuget.org policyの権限と確認を要し、一般のGitHub/release controllerではない。
GitHubのread/writeは`github-operations`のaccount、pre-read、曖昧な結果、不可逆操作の規律を維持する。

## 外部guide

[Modern Web Guidance](https://github.com/GoogleChrome/modern-web-guidance/tree/650eb83619134adb947b1ee8755e6511270bc444)は`modernWebGuidance` inputの`650eb83619134adb947b1ee8755e6511270bc444`を固定し、[Apache-2.0](https://github.com/GoogleChrome/modern-web-guidance/blob/650eb83619134adb947b1ee8755e6511270bc444/LICENSE)のsource全体を保持する。
既存のhome assetとmanaged-artifact機構で`~/.local/share/dotfiles-agent/references/modern-web-guidance/`へsourceを参照させる。
対象機能の`skills/modern-web-guidance/guides/<topic>/<guide>.md`だけを原文で読み、全frontendへ強制起動する同梱`SKILL.md`はregistryへ採用しない。
guideを独自Skillへ再編集せず、projectのbrowser supportと前提を照合する。

## 標準Skillの配備条件

`property-testing`の正本はarchitecture-standardの`skills/property-testing/SKILL.md`であり、`requiresSkills = [ \"standard-apply\" ]`、`requiresCapabilities = [ ]`を使う。
published revisionを固定してwhole sourceから直接採用し、architectとimplementerのdynamic routeへ登録する。
CLIとterminalの公開契約は`standard-apply`から標準の`structure/surfaces/console/layout.md`へ進み、moduleのinterfaceとseamは`codebase-design`、入力領域と独立oracleとshrinkingは`property-testing`、実装は既存の`tdd`が扱う。
標準の`skills/cli-design/`はwhole source内に保持するが、named discoveryとsubagent routeには登録しない。
未commitのlocal checkoutを恒久sourceにせず、標準の公開後に固定inputとlockを更新する。

## Custom Skillの責務

writing系では、`commit-writing`がcommitの目的、`change-writing`が差分の説明、`description-writing`が読者の問いに沿うREADMEや技術文書の構成を所有する。
`documentation-writing`は宣言の契約、`comment-writing`は実装のWhy notと有効な制約、`ja-writing`は標準に沿う日本語の表現を扱う。
これらはcoding workflowの原版を別名へ分割したものではない。

`web-research`は問いをclaimへ分解し、URL探索、本文取得、library docsのtool選択、一次資料の比較、引用可能な根拠の統合までを自立して扱う。
`repository-research`は未知のlocal概念や関係を探索し、現在のsourceでclaimを検証する。
既知のexact text、path、symbolはraw toolで直接調べ、依存graphは`dependency-analysis`、具体的変更のblast radiusは`impact-analysis`へ渡す。

`dependency-analysis`はnode、edge、方向、granularityを定義して依存の事実を作り、`impact-analysis`は一つの具体的変更からcode、data、runtime、deployment、契約、所有へ影響を追う。
設計やarchitecture探索とは成果物が異なるため、依存の事実と具体的変更の影響を独立して所有する。

`browser-operation`は実surfaceの状態遷移と副作用境界、`github-operations`はaccount target、resource identity、write前後のstate、曖昧な結果、不可逆操作を所有する。
`memory`はrecallの一次source検証と保存admission、privacy、failure semanticsを扱い、repository調査や正本を代替しない。
`browser-performance`はtraceの測定条件を固定し、loading、interaction、CLS、networkからresourceとsourceへ原因を追う。
LCPとheapの専門仕事は、同じbaselineと観測を専門Skillへ渡し、重複計測を避ける。
代表scenarioは[`agents/fixtures/browser-performance-skill.json`](../../agents/fixtures/browser-performance-skill.json)に置き、native性能、LCPだけの依頼、a11y、既知の経路verificationを近接する別仕事として扱う。

`environment-design`は永続的な訂正や改善を標準、dotfiles、upstream、対象project、memoryの適切なownerへ振り分ける。
`skill-design`は基礎モデル、policy、reference、script、tool、既存Skillで足りるかを先に判断し、独立したSkillの要否とroutingを設計する。

`ui-design`は利用者の仕事、実content、既存design systemから、情報階層、interaction、visible state、feedback、responsive、accessibilityを実装前のbriefへ閉じる。
module内のcomponent構成やinterfaceは`codebase-design`へ渡し、確定したUIの実装を別のcustom Skillに分けない。
`security-review`は明示的な脅威モデリングと、候補の発見、成立条件の検証、攻撃経路の追跡、修正への引渡しを所有する。
phase referenceは同じdirectoryから解決し、別SkillのfrontmatterやCodex専用のreport directiveを持たない。

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

runtime本文は[admissionと評価](../../skills/skill-design/skill/references/admission-and-evaluation.md)だけを必要時に読み、sourceの履歴とlegal情報はこの保守文書に置く。
代表scenarioは[`agents/fixtures/skill-design-skill.json`](../../agents/fixtures/skill-design-skill.json)に置き、Skillを作らない判断と近接Skillへ渡す判断も成功として扱う。

| Donor | Revision / date | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|---|
| Codex system `skill-creator` | Codex CLI `0.147.0`、2026-08-14 | 配布物内に個別表示なし。本文は非転載 | conciseな本文、descriptionでのrouting、必要なresourceだけを追加すること | Skill作成を既定にする入口、mechanism gateの欠如、local版と同じnameによるrouting競合。`skills.config`で無効化した |
| [Anthropic skill-creator](https://github.com/anthropics/claude-plugins-official/tree/ae21a9367949f92df4e31231d7efe43eaa08207c/plugins/skill-creator) | `ae21a9367949f92df4e31231d7efe43eaa08207c` | Apache-2.0 | realistic test、baselineとの対照、iteration、description routing、leanな本文、ablationに相当する削減 | Claude専用subagent prompt、viewer、grader、description optimizer、directory workflow |
| [OpenAI Academy: Using skills](https://openai.com/academy/skills/) | 2026-04-10 | [Terms of Use](https://openai.com/policies/terms-of-use/)。本文は非転載 | 反復task、inputとoutputとguardrail、組合せ可能な小さいbuilding block、toolを含むworkflow | ChatGPTのinstall、workspace、共有手順 |
| [dotnet skills](https://github.com/dotnet/skills/tree/7953ba85365219dc7df5d73634e1f9d0bfabf0b9) | `7953ba85365219dc7df5d73634e1f9d0bfabf0b9` | MIT | natural stimulus、baseline対Skill、dormancy guard、outcome中心のrubric、eval自体のfault分離、retire判断 | Vally schema、.NET固有fixture、sign testの固定閾値、repository専用CI |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | `2ed6c52c9d7e5e56942508591085fd45dea277d3` | MIT | 新規所有物の前に不要、既存mechanism、標準機能、導入済みdependencyを比較するlens、安全性を削減対象にしないこと | 全coding taskへの常時注入、mode、line数とtoken削減をSkill admissionの目的にすること |



### ui-designで採用したdonor

`ui-design`は、利用者の仕事、実際のcontentと範囲、既存screenとdesign systemを先に読み、情報階層、interaction、visible state、feedback、recovery、responsive、accessibilityを一つのbriefへ閉じる。Impeccableのshape procedure、Hallmarkの既存system確認、Addy Osmaniのcontentとstate、WondelAIのaffordanceとmicrointeractionを組み合わせる。theme catalog、固定score、万能な禁止則、実装workflowは採らない。

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Impeccable shape](https://github.com/pbakaus/impeccable/blob/c8f476b330395031bc8f7a7aee8d848bc85c81e4/.agents/skills/impeccable/reference/shape.md) | Apache-2.0 | purpose、実content、範囲、stateから階層とinteractionを決め、briefで止める手順 | 固定質問round、theme catalog、script、全体orchestrator |
| [Hallmark](https://github.com/Nutlope/Hallmark/blob/13ac0ec7e148655948100b6396439e481361d690/skills/hallmark/SKILL.md) | MIT | 既存tokenとcomponentの確認、taskに対応する構造、架空metricの禁止 | 固定gate、theme catalog、rotation、cache、buildとauditの所有 |
| [Anthropic frontend-design](https://github.com/anthropics/claude-plugins-official/blob/ae21a9367949f92df4e31231d7efe43eaa08207c/plugins/frontend-design/skills/frontend-design/SKILL.md) | Apache-2.0 | purpose、audience、制約から一貫した方向を導くこと | 極端なaesthetic、特徴的font、motion、unexpected layout、code実装、毎回異なる外観の強制 |
| [Addy Osmani frontend-ui-engineering](https://github.com/addyosmani/agent-skills/blob/be42637c5af93fdc8526b68ec2f2651b930f316c/skills/frontend-ui-engineering/SKILL.md) | MIT | design system、content-first layout、semantic token、意味のある状態 | React構造、固定breakpoint、行数threshold、実装workflow |
| [WondelAI design-everyday-things](https://github.com/wondelai/skills/blob/6bac1534f9f256a56fc2b4dd0e70b9a692758966/design-everyday-things/SKILL.md)、[microinteractions](https://github.com/wondelai/skills/blob/6bac1534f9f256a56fc2b4dd0e70b9a692758966/microinteractions/SKILL.md) | MIT | affordance、signifier、mapping、constraint、feedbackと、trigger、rule、feedback、recovery | score、固定時間、signature moment、review severity |
| [Anthropic frontend-design](https://github.com/anthropics/skills/blob/683bc88e56f3e09ba94f7055977f3d3aa499f202/skills/frontend-design/SKILL.md) | [sourceのcomplete terms](https://github.com/anthropics/skills/blob/683bc88e56f3e09ba94f7055977f3d3aa499f202/skills/frontend-design/LICENSE.txt) | 実contentとproductの語彙、焦点を一箇所へ集めること、copyと状態の一貫性、briefとの比較 | 毎回異なるlook、固定palette、type scale、character count、実装workflow、記憶にある好みだけでdirectionを変えること |
| [Web Interface Guidelines](https://github.com/vercel-labs/web-interface-guidelines/blob/434b7f91364665f2f733b310ec54809bf8f37937/command.md) | [MIT](https://github.com/vercel-labs/web-interface-guidelines/blob/434b7f91364665f2f733b310ec54809bf8f37937/LICENSE) | native semantics、focus、form、content増幅、locale、motion、asset寸法をUI briefと指定axisのreviewで確認すること | 全listの固定virtualization閾値、全font preload、固定case、全stateのURL同期、概算やstatic codeから実画面合格を宣言すること |


frontend-design原版は配備せず、前提が合う方法だけを実装前の`ui-design`へ統合する。
承認済みbriefと既存design systemが、特徴的なlookやdonorの好みより優先する。
frontend実装やreviewのためだけの同役割Skillは増やさない。

代表scenarioは[`agents/fixtures/ui-design-skill.json`](../../agents/fixtures/ui-design-skill.json)に置く。


### browser-performanceとsecurity-reviewの方法

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Cloudflare web-perf](https://github.com/cloudflare/skills/tree/41e0ffd9815f3da356b8dffed83e81996cb9873c) | [Apache-2.0](https://github.com/cloudflare/skills/blob/41e0ffd9815f3da356b8dffed83e81996cb9873c/LICENSE) | browser traceからnetwork、resource、sourceへ辿ること、計測条件とbefore/afterの比較、推定と測定の区別 | 固定tool引数、navigation-onlyのINP、one-flow未使用判定、architecture一般論、source wrapperの再配備 |
| [OpenAI security-threat-model](https://github.com/openai/skills/blob/49f948faa9258a0c61caceaf225e179651397431/skills/.curated/security-threat-model/SKILL.md) | [Apache-2.0](https://github.com/openai/skills/blob/49f948faa9258a0c61caceaf225e179651397431/skills/.curated/security-threat-model/LICENSE.txt) | boundaryとdata flowの証拠、asset、attackerの能力と非能力、具体的abuse path、likelihoodとimpact、現controlと推奨controlの分離 | 固定出力template、固定件数、必ず質問して待つgate、runtimeとCIを一つの露出として扱うこと、脅威仮説を検証済みfindingとして報告すること |
| [Microsoft review guidance](https://github.com/microsoft/vscode/tree/ff275e332050c5babc3dc4df3ac91baa34c2aa6cd) | [MIT](https://github.com/microsoft/vscode/blob/ff275e332050c5babc3dc4df3ac91baa34c2aa6cd/LICENSE.txt) | 全changed subsystemの追跡、問題解決との因果関係、最小rangeと影響の根拠、無関係なcleanupの分離 | VS Code固有のstyleとextension要件、全PRへの固定rubric、変更前からある問題の混入 |

これらの方法は当repositoryの手順として書き直し、runtime本文や実行referenceにdonor呼出しを残さない。
legal情報と採否の記録はこの保守文書に置き、外部原版そのものの本文とlicenseは固定sourceで保持する。

## Custom Skillの採用条件

候補ごとに、Skillなしの代表scenarioで不足を観測する。
Skillありの同種scenarioで成果、routing、process、restraint、compositionを比較し、内容、reference、script、Skill自体を除いて結果が変わらなければ削除する。

sourceの分類や作者名をruntime構造に使わない。
custom Skillの詳細な知識は一段のreferenceへ分け、`SKILL.md`には発火後に必要なprocedureと打ち切り条件を置く。
