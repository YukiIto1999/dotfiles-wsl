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
各`module.nix`がsource、`requiresSkills`、`requiresCapabilities`、`optionalCapabilities`を`dotfiles.skills.registry`へ登録し、外部Skillも同じ契約を使う。
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
`requiresCapabilities`はSkill全体の配備条件であり、`optionalCapabilities`は条件付き手順の入口を表す。
任意のCapabilityが未配備でもSkill全体を外さず、実行時には該当する手順だけを使わない。
共通policyのCapability入口表は両方から導き、toolの入口を作るためだけにSkill全体を必須依存へ変えない。

MCP専用の薄いwrapperは置かない。
`repository-research`は探索経路とsource検証、`browser-operation`は要求と変更pathから実画面と業務結果へ至る受入判断、`github-operations`はidentity、pre-read、idempotency、不可逆操作、`memory`はrecallの検証、保存admission、privacy、failure fallbackを所有する。
SkillとCapabilityの対応、subagentごとのrouteは[`agents/subagents/routing.nix`](../../agents/subagents/routing.nix)を正本にする。

## 直接採用

固定revisionの正本は[`flake.nix`](../../flake.nix)と[`flake.lock`](../../flake.lock)、採用IDとdirectory pathの正本は[`skills/plugins/module.nix`](../../skills/plugins/module.nix)である。
Orcaの操作Skillとarchitecture-standardの運用Skillに加え、次の固定sourceから個別Skillを採用する。
sourceはrepository全体またはSkillを同梱したpublished package全体を保持し、rootのlicenseと同梱資材を残したままSkill directoryを配備先から参照する。

| Source | Flake input | 固定revision | License |
|---|---|---|---|
| [Matt Pocock skills](https://github.com/mattpocock/skills/tree/4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d) | `mattSkills` | `4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d` | [MIT](https://github.com/mattpocock/skills/blob/4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d/LICENSE) |
| [Chrome DevTools MCP](https://registry.npmjs.org/chrome-devtools-mcp/-/chrome-devtools-mcp-1.10.1.tgz) | `chromeDevtoolsMcp` | `1.10.1`（gitHead `e52c6b59b476c5e04d8dd9fd4bd017ba3b3d65df`） | [Apache-2.0](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/e52c6b59b476c5e04d8dd9fd4bd017ba3b3d65df/LICENSE) |
| [.NET skills](https://github.com/dotnet/skills/tree/0dcd43ceb15e15a2c45dd54075fbcf3a30632154) | `dotnetSkills` | `0dcd43ceb15e15a2c45dd54075fbcf3a30632154` | [MIT](https://github.com/dotnet/skills/blob/0dcd43ceb15e15a2c45dd54075fbcf3a30632154/LICENSE) |
| [mizchi explainer](https://github.com/mizchi/explainer/tree/578defba7249fde5366689424ed6017f76b5598b) | `explainerSkills` | `578defba7249fde5366689424ed6017f76b5598b` | [MIT](https://github.com/mizchi/explainer/blob/578defba7249fde5366689424ed6017f76b5598b/LICENSE)。同梱`first-reader`は[Apache-2.0とNOTICE](https://github.com/mizchi/explainer/blob/578defba7249fde5366689424ed6017f76b5598b/skills/first-reader/NOTICE)を保持 |

次のpathは各固定sourceのrootからの相対pathであり、directoryの配置やSkill名をlocalの命名体系へ変換しない。
Chrome MCPのruntimeと採用Skillは同じpublished packageを参照し、runtimeのversionもその`package.json`から取得する。

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
| `explainer` | explainer `skills/explainer` | 読者の既知を除いた速習資料、sourceと出力の注釈、図とHTML |
| `explainer-book` | explainer `skills/explainer-book` | 概念の順序、章ごとの到達点と演習が必要な教材 |
| `first-reader` | explainer `skills/first-reader` | freshな模擬readerによる読書経験とrecallの報告。本文は書き換えない |

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
SonarQubeの補助根拠が必要なbranchだけ、callerが`code-quality`で取得と現在sourceへの適用を確認してaxis briefへ渡す。
`code-review`の`optionalCapabilities`に登録するが、原版本文を変更せず、SonarQubeの未配備で一般のreviewを止めない。
未commit差分をreview対象へ含めるために無断でcommitせず、別sessionが作業中のcheckoutでは`HEAD`を動かさない。
reviewerは目的をrequest、issue、specから固定し、全changed subsystemのbehaviorをcallerとtestまで追う。
testがgreenでも目的との因果関係がない変更を指摘し、unrelated cleanupを同じ修正へ混ぜない。
findingは発生条件、影響、最小のchanged rangeと根拠を持ち、指定したaxis内だけで返す。

`description-writing`は、一次資料に基づく内容、読者の問いに沿う構成、返った所見を採用する編集判断を所有する。
READMEの開始手順、setup、tutorialなど再現する操作がある場合だけ、独立したcustom [`article-reproduction`](../../skills/article-reproduction/skill/SKILL.md)へ渡す。
完成した記事と添付のrevision、読者と到達点、環境と開始状態、順序付き操作、入力、期待exitと個別streamと生成物、既存証拠、許可範囲を渡し、判定とlocator付きblocking点を受け取って修正へ戻る。
書き手側では同じ再現性loopを重ねず、変更した手順や前提だけを同じownerへ戻す。
既存記事の単独reviewも同じownerが扱い、概念説明や単なる参照表には起動しない。
`reviewed-only`、`reproduced`、`failed`、`blocked`は記述review、実行証拠との一致、観測した矛盾、前提または権限不足を区別し、未実行を再現済みとは扱わない。

sourceに照らす図、出力注釈、HTMLを含む速習資料の仕事だけを原版`explainer`へ渡し、章立てと演習が必要なら`explainer-book`を使う。
依頼されたbeta readや重要文書の独立した理解確認は原版`first-reader`へ渡し、同じrevisionで既に得たreader結果を再利用する。
freshなreaderを起動できないworkerは入力と未実施理由をtop-level callerへ返し、自分の既知draftの再読で代用しない。
模擬readerの反応とlogからのrecallは、実commandの証拠や実際の翌日の人間の記憶測定とは区別する。
用語の意味、context、`GLOSSARY.md`、domainのADRを変更する仕事は既存の`domain-modeling`へ渡し、実装mapをdomain定義へ混ぜない。
architectの`explainer`と`article-reproduction`、implementerの`article-reproduction`は該当taskだけのdynamic routeであり、一般設計やcodingの必須preloadにしない。
raw sourceの採用は`mizchi/explainer`に限り、donorとして調べた`mizchi/skills`をwhole sourceの配備対象にはしない。
外部scriptの実行入口と制約は[toolingの外部CLI](../reference/tooling.md#外部cli)が持つ。

`browser-operation`は要求と変更pathから重要な実経路、状態遷移、contentと表示条件を選び、fresh DOM操作、実際に読んだrendered screenshot、業務結果を対応させる。
関連する拒否、回復、契約が必要とする再取得までclaimごとに閉じ、未確認条件と証拠を返す。
永久testの作成や専門監査は別ownerとし、配備ではbrowser-automationだけを要求する。
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

独自Skillは、単独で成立する判断方法と、Skillやtoolを組み合わせる作業手順の二種類に分ける。
判断方法には、必要な証拠が不足したときだけ調査や観測を委譲する分岐を置き、MCPやbrowserを常時の配備条件にしない。
作業手順には、公開入口、渡す対象と証拠、返る成果、再開地点、利用できない場合の扱いを置く。
この区分は責務の説明であり、frontmatterやregistryへ分類用のfieldを追加しない。

| 判断方法 | 所有する判断 | 必要時の導線 |
|---|---|---|
| `change-writing` | 明示した差分から変更の目的と利用者への影響を説明する判断 | 差分と検証記録を読み、日本語の表現を`ja-writing`へ渡す。 |
| `comment-writing` | 実装commentを残す理由と最小の内容の判断 | 正本の標準と制約を読み、日本語の表現を`ja-writing`へ渡す。 |
| `description-writing` | 一次資料に基づく内容と読者の問いに沿う構成の判断 | 再現する手順を`article-reproduction`、速習資料を原版`explainer`、独立した理解確認を原版`first-reader`へ条件付きで渡し、返却結果から編集を再開する。 |
| `article-reproduction` | 記事の開始条件と操作から到達点を再現できるかの判断 | 記述reviewと実行証拠を区別し、必要なbrowser操作や.NET testだけを専門入口へ渡す。 |
| `documentation-writing` | 宣言の契約をdocumentation commentへ記す判断 | 宣言と実装と契約を調べ、日本語の表現を`ja-writing`へ渡す。 |
| `ja-writing` | 日本語の表現と推敲の判断 | 正本の標準を読み、渡された文章を扱う。 |
| `dependency-analysis` | nodeとedgeを固定して依存の事実を作る判断 | 未知の概念と関係だけ`repository-research`へ渡し、設計と診断を別の仕事として扱う。 |
| `impact-analysis` | 一つの変更から契約と利用箇所と運用への影響を追う判断 | 不足する調査を`repository-research`へ渡し、設計や診断へ影響の証拠を引き継ぐ。 |
| `skill-design` | Skillの要否、責務と導線、実行結果に基づく採否の判断 | 固定したcriteriaとfresh実行で改訂し、規範や配備先の不足だけを`environment-design`へ渡す。 |
| `ui-design` | 実contentと既存design systemに基づく実装前briefの判断 | 未知の構造は`repository-research`、必要な実surfaceの観測は`browser-operation`、実装構造は`codebase-design`へ渡す。 |
| `security-review` | 脅威モデリングから候補の検証と攻撃経路へ進む判断 | 不足する証拠だけ調査や観測のSkillへ渡し、security判断とphaseの進行を引き取る。 |

| 作業手順 | 公開入口 | 合成と引継ぎ |
|---|---|---|
| `browser-operation` | `browser-automation`のPlaywright MCP | 要求と変更pathから実画面と業務結果のmatrixを作り、観測した証拠と未確認条件を返す。専門監査や原因診断は別の依頼として渡す。 |
| `browser-performance` | `browser-diagnostics`のChrome DevTools MCP | 固定した測定条件と観測をLCPの専門Skillや`heap-analysis`へ渡し、戻った証拠から診断を続ける。 |
| `heap-analysis` | `heap-diagnostics`の公開MemLab MCP | browserのcaptureだけを`browser-performance`へ委譲し、返ったcaller所有のprivate fileを解析する。 |
| `github-operations` | `github-resources`のaccount別GitHub MCP | accountと対象resourceを固定し、write前後の状態を確認する。 |
| `memory` | `project-memory`の公開MCP | recallを一次資料で検証し、保存の受理と永続化を区別する。 |
| `repository-research` | `repository-search`のZvec-Grep MCPとnative repository tools | 未知の概念を探索し、graphと具体的変更の影響をそれぞれの判断方法へ渡す。 |
| `web-research` | clientのnativeなWeb検索とURL取得、`library-documentation`のContext7 MCP | 探索と本文取得をclientのtoolで行い、library docsはContext7へ渡す。native toolを持たないsubagentは呼出し元へ実行を依頼する。localの問いは`repository-research`へ渡す。 |
| `environment-design` | ownerの正本と既存Skillの入口 | 外部toolの採用や差替えは、更新後のcallerと配備契約を確認してから変更を振り分ける。標準、dotfiles、upstream、対象project、memoryへ渡し、Skillの責務や手順の変更は`skill-design`へ渡す。 |
| `commit-writing` | Gitのstaged diffと対象repositoryのcommit-msg hook | 一つの目的に閉じた件名を作り、実際のhookを通す。日本語の推敲は条件付きで`ja-writing`へ渡す。 |

`requiresSkills`は無条件に必要な配備前提だけを表す。
言語に応じた推敲、追加の観測、対象が別の仕事だった場合のhandoffは条件付きの導線として本文へ残す。
containerを背後に持つMCPも公開Capabilityから使い、Skillからproviderのprocessやdatabaseへ直接接続しない。
既知のexact textとpathとsymbolはRead、Grep、LSPなどで、決定的なCLI操作は実binaryで直接扱い、一回のtool呼出しをSkillで包まない。
本文の`xd://`入口はURI deviceを公開するclient用の例であり、MCPを直接呼ぶclientでは現在のネイティブな公開tool名とschemaへ対応させる。

独自Skillの本文と実行用referencesには、着想元の紹介やadoption rationaleを置かない。
来歴とlicenseはこの文書の次節に置き、正本の標準への参照と実際の委譲先Skill名は実行に必要な導線として残す。
採用した外部原版は変更しない。
phase referenceは同じdirectoryから解決し、別Skillのfrontmatterや特定clientだけのreport directiveを持たない。
browser性能の代表scenarioは[`agents/fixtures/browser-performance-skill.json`](../../agents/fixtures/browser-performance-skill.json)に置く。
外部toolの統合は[`agents/fixtures/environment-integration-skill.json`](../../agents/fixtures/environment-integration-skill.json)の代表scenarioで、callerと実装、共通配備と現状調査を区別して評価する。

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

### 技術記事と環境改善のdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [tech-article-reproducibility](https://github.com/mizchi/skills/blob/62f580819410cb1d398e4d7f234bbd0aad1c1a15/tech-article-reproducibility/SKILL.md) | 個別licenseなし。[root README](https://github.com/mizchi/skills/blob/62f580819410cb1d398e4d7f234bbd0aad1c1a15/README.md#license)のMIT default宣言を記録し、本文は非転載 | 記事の環境、入力、操作、到達点を辿り、再現を止める不足を引用とlocatorへ結び付ける独立した判断 | 想像上のreader実行を実証にすること、20点のpublish閾値、主観的成功率、個人path、固定WebFetch、raw本文の配備 |
| [explainer verify-doc](https://github.com/mizchi/explainer/blob/578defba7249fde5366689424ed6017f76b5598b/skills/explainer/scripts/verify-doc.mjs#L46-L75) | MIT。固定raw sourceは別途そのまま採用 | wrapperの成功と内側のexit、stdout、stderrを区別する必要性を示す具体的なcheckerの限界 | checkerを書き換えた代用品、`VERIFIED`を再現性の独立gateにすること |
| [extract-glossary](https://github.com/mizchi/skills/blob/62f580819410cb1d398e4d7f234bbd0aad1c1a15/extract-glossary/SKILL.md) | 個別licenseなし。root READMEのMIT default宣言。本文は非転載 | onboarding文書で既存語彙と入口を読み、source付きの実装mapをdomain定義から分けること | 別glossary Skill、固定fileとdiagram一式、名前から推測したdomain定義、実装mapの`GLOSSARY.md`への転記 |
| [retrospective-codify](https://github.com/mizchi/skills/blob/62f580819410cb1d398e4d7f234bbd0aad1c1a15/retrospective-codify/SKILL.md) | 個別licenseなし。root READMEのMIT default宣言。本文は非転載 | `environment-design`で観測した失敗と最後の成立を入力と出力の差で対にし、もっともらしい説明と因果の証拠を分けること | 新しいretrospective owner、既存規律が読まれなかった場合の重複guidance、global ast-grep規則、配備copyの直接編集 |

再現性の入力と返却は[reproduction-contract](../../skills/article-reproduction/skill/references/reproduction-contract.md)が所有し、代表scenarioは[`skills/article-reproduction/fixtures/scenarios.json`](../../skills/article-reproduction/fixtures/scenarios.json)に置く。
[`agents/fixtures/writing-skills.json`](../../agents/fixtures/writing-skills.json)の執筆handoff例は期待するbehaviorを記したfixtureであり、変更後の発火や実行成功を測定した記録ではない。
`environment-design`の既存のowner選択と重複排除は維持し、教訓から検査、policy、方法のどれを選ぶかは選んだownerの入口へ返す。



### web-researchで採用したdonor

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Matt Pocock research](https://github.com/mattpocock/skills/blob/8b78b531ab965735c5dc74f6f7a219e1e37326df/skills/engineering/research/SKILL.md) | MIT | claimを一次資料まで辿り、sourceが直接支える範囲で結論を書く | 常にbackground agentを使うこと、調査のたびにfileを作ること |
| Context7の配備時tool schema | 該当なし。[`package.nix`](../../capabilities/library-documentation/context7/mcp/package.nix)の固定revisionから配備する | library docsの入口と、実在する引数 | 配備されていないtool、SDK専用引数、固定件数のsource取得 |

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

`skill-design`はempiricalな実行と振り返りを中心とする独立したOMP Skillへ置き換えた。
Iteration 0、固定したcritical、fresh実行、Understanding / Planning / Execution / Formattingの診断、Issue / Cause / General Fix Rule、失敗台帳、一テーマの反復、holdoutと停止条件を一つの手順にした。
旧版のmechanism gate、no-skill対照、natural trigger、near-miss、composition、restraint、ablation、retireは別の評価loopにせず、その手順へ組み込んだ。

共通手順は[SKILL.md](../../skills/skill-design/skill/SKILL.md)が持ち、評価の起動時だけ[fresh executionの契約](../../skills/skill-design/skill/references/fresh-execution.md)を読む。
代表scenarioは[`agents/fixtures/skill-design-skill.json`](../../agents/fixtures/skill-design-skill.json)に置き、Skillを作らない判断と近接ownerへ渡す判断も成功として扱う。
tool-freeなstateless completionのmethod-onlyと、実toolや自然発火を観測するfull-environmentを区別し、候補を除いた初期環境を作れない場合のbaselineは未測定とする。
top-levelがdispatchと評価を所有し、workerは一つのscenarioの成果と診断を返すため、子から再帰的に評価者を起動しない。
sourceの完成、形式validatorの成功、実測した発火と採否を別の状態として報告する。

| Donor | Revision / date | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|---|
| [empirical-prompt-tuning](https://github.com/mizchi/skills/blob/62f580819410cb1d398e4d7f234bbd0aad1c1a15/empirical-prompt-tuning/SKILL.md) | `62f580819410cb1d398e4d7f234bbd0aad1c1a15` | 個別licenseなし。[root README](https://github.com/mizchi/skills/blob/62f580819410cb1d398e4d7f234bbd0aad1c1a15/README.md#license)のMIT default宣言。本文は非転載 | Iteration 0、phase別の詰まり、固定critical、構造化した振り返り、失敗台帳、一テーマの反復、holdoutと停止 | raw本文、Claude Task専用contract、未取得usageの推定、自己採点の転記、作者の効率閾値の普遍化、別eval owner |
| [optimizing-descriptions](https://github.com/mizchi/skills/blob/62f580819410cb1d398e4d7f234bbd0aad1c1a15/optimizing-descriptions/SKILL.md)、[Agent Skills guidance](https://agentskills.io/skill-creation/optimizing-descriptions) | 固定revision、公式guidanceは2026-10-07取得 | donorはroot READMEのMIT default宣言。guidance本文は非転載 | 意図に基づくpositiveとnear-miss、freshな複数trial、trainとholdoutの分離、descriptionだけを変える枝 | 失敗queryの単語の列挙、見たholdoutを未使用と称すること、tool-free選択を実Skill discoveryと称すること |
| [Codex skills](https://developers.openai.com/codex/skills/)、[Anthropic best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)、[agent eval guidance](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) | 2026-10-07取得 | 公式本文は非転載 | triggerと本文の整合、現実的なtask、安定した環境、成果と実行記録を照合するgrader | 形式検査や自己申告だけの能力判定、provider専用harnessとviewer |
| [Matt writing-for-agents](https://github.com/mattpocock/skills/blob/4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d/skills/productivity/writing-for-agents/SKILL.md)、[Skill mechanics](https://github.com/mattpocock/skills/blob/4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d/skills/productivity/writing-for-agents/SKILL-MECHANICS.md) | `4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d` | MIT | packageを書く枝でのcontext pointer、情報階層、明確な完了条件、削減 | 全構造判断や評価への必須preload、別のprompt改善loop |
| [dotnet skills](https://github.com/dotnet/skills/tree/7953ba85365219dc7df5d73634e1f9d0bfabf0b9) | `7953ba85365219dc7df5d73634e1f9d0bfabf0b9` | MIT | natural stimulus、no-skill対照、dormancy guard、outcome中心のrubric、eval fault分離、retire | Vally schema、.NET固有fixture、sign testの固定閾値、repository専用CI |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | `2ed6c52c9d7e5e56942508591085fd45dea277d3` | MIT | 不要、既存mechanism、標準機能、導入済みdependencyを先に比較し、安全性を削減対象にしないこと | raw採用、全coding taskへの常時注入、line数やtoken削減をadmissionの目的にすること |

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


### browser-operationの実画面受入

要求と変更path、状態遷移、表示条件、画像と業務結果のmatrixは、利用者が報告した実画面確認の不足を埋めるcustomの設計である。
以下のdonorが完全な受入方法を提供するとしたものではなく、永久test suiteやCIのownerも増やさない。

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [playwright-test](https://github.com/mizchi/skills/blob/62f580819410cb1d398e4d7f234bbd0aad1c1a15/playwright-test/SKILL.md) | 個別licenseなし。root READMEのMIT default宣言を記録し、本文とcodeは非転載 | 条件に基づく待機、one-shot取得との区別、必要なrequest待機の事前登録、利用者向けlocator、dialog閉鎖後の結果確認 | raw採用、configとCIとretry template、auth抽出、API mockとHAR、合成event、DnD内部操作、固定case数 |
| [Playwright best practices](https://playwright.dev/docs/best-practices#test-user-visible-behavior)、[actionability](https://playwright.dev/docs/actionability#visible)、[screenshots](https://playwright.dev/docs/screenshots#full-page-screenshots)、[emulation](https://playwright.dev/docs/emulation#viewport) | 公式guidance。2026-10-07取得。本文は非転載 | 実際の利用者の出力、fresh locator、結果条件、viewport画像とfull-pageの違い、resizeと実deviceの違い | DOMのvisible判定だけでの画面合格、forceによる迂回、画像pathだけの目視済み主張、単一経路を全条件の保証にすること |

### browser-performanceとsecurity-reviewの方法

| Donor | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|
| [Cloudflare web-perf](https://github.com/cloudflare/skills/tree/41e0ffd9815f3da356b8dffed83e81996cb9873c) | [Apache-2.0](https://github.com/cloudflare/skills/blob/41e0ffd9815f3da356b8dffed83e81996cb9873c/LICENSE) | browser traceからnetwork、resource、sourceへ辿ること、計測条件とbefore/afterの比較、推定と測定の区別 | 固定tool引数、navigation-onlyのINP、one-flow未使用判定、architecture一般論、source wrapperの再配備 |
| [OpenAI security-threat-model](https://github.com/openai/skills/blob/49f948faa9258a0c61caceaf225e179651397431/skills/.curated/security-threat-model/SKILL.md) | [Apache-2.0](https://github.com/openai/skills/blob/49f948faa9258a0c61caceaf225e179651397431/skills/.curated/security-threat-model/LICENSE.txt) | boundaryとdata flowの証拠、asset、attackerの能力と非能力、具体的abuse path、likelihoodとimpact、現controlと推奨controlの分離 | 固定出力template、固定件数、必ず質問して待つgate、runtimeとCIを一つの露出として扱うこと、脅威仮説を検証済みfindingとして報告すること |
| [Microsoft review guidance](https://github.com/microsoft/vscode/tree/ff275e332050c5babc3dc4df3ac91baa34c2aa6cd) | [MIT](https://github.com/microsoft/vscode/blob/ff275e332050c5babc3dc4df3ac91baa34c2aa6cd/LICENSE.txt) | 全changed subsystemの追跡、問題解決との因果関係、最小rangeと影響の根拠、無関係なcleanupの分離 | VS Code固有のstyleとextension要件、全PRへの固定rubric、変更前からある問題の混入 |

これらの方法は当repositoryの手順として書き直し、runtime本文や実行referenceにdonor呼出しを残さない。
legal情報と採否の記録はこの保守文書に置き、外部原版そのものの本文とlicenseは固定sourceで保持する。
browserのinteractionはinputから最初のpaintまでの指標と、非同期response後の結果表示までを分け、request、main-thread work、layout、paintを同じtraceとsourceへ対応させる。
会話を再開してもproviderのpageとtraceの保持は保証されないため、現在の公開toolで可用性を確認し、取得済みartifactと新sessionの観測を区別する。

## Custom Skillの採用条件

候補ごとに、Skillなしの代表scenarioで不足を観測する。
Skillありの同種scenarioで成果、routing、process、restraint、compositionを比較し、内容、reference、script、Skill自体を除いて結果が変わらなければ削除する。

sourceの分類や作者名をruntime構造に使わない。
custom Skillの詳細な知識は一段のreferenceへ分け、`SKILL.md`には発火後に必要なprocedureと打ち切り条件を置く。
