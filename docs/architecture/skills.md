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

2026-08-13 時点の構成は、次の Skill を配備対象にしている。rebuild 前の環境と起動済みagentには古い配備が残り得る。

- local: `changelog-generator`、`code-reviewer`、`git-commit-writer`、`ja-writing`、`pr-description-writer`、`web-researcher`
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
| 特殊 | `skill-creator`、`grill-with-docs`、`tdd`、`refactoring`、`prototype`、`migration` |
| writing | `ja-writing`、`commit-writing`、`change-writing`、`description-writing`、`documentation-writing`、`comment-writing` |
| research | `web-research` |
| analysis | `bug-analysis`、`dependency-analysis`、`impact-analysis`、`performance-analysis` |
| review | `code-review`、`architecture-review`、`test-review`、`interface-review`、`database-review`、`naming-review`、`ui-review`、`browser-review` |
| design | `ui-design`、`code-design`、`module-design`、`interface-design`、`architecture-design`、`db-design`、`component-design`、`test-design`、`error-design` |
| modeling | `domain-modeling`、`data-modeling` |

## 責務境界

`commit-writing` は一つのcommitが解決する問題と目的を履歴へ残す。`change-writing` は既に存在する差分を、PR、changelog、release note、handoffの読み手へ説明する。`description-writing` はREADME、ADR、仕様、報告、技術解説を、読者の問いと文書の目的から構成する。差分固有の説明を一般文書へ混ぜない。

`documentation-writing` は宣言の契約を書く。目的と、該当する事前条件、事後条件、不変条件、副作用、失敗条件を扱う。`comment-writing` は実装コメントを書く前に、構造、命名、コード本体で表せないかを調べる。残すのは、自然に見える実装を採らなかった理由と、現在も有効な制約だけである。変更履歴、古いコード、処理の言い換えは扱わない。

`web-research` は外部の問いに対してsourceを探索、評価、比較し、引用可能な根拠を作る。`grill-with-docs` は未解決のproductやdomain判断を利用者との質問で詰め、共有理解をrepository文書へ残す。外部事実の収集と、利用者が所有する決定を同じ仕事にしない。

`domain-modeling` は概念と語彙を定義する。`naming-review` は定義済みの意味を入力に、code、schema、DB、UI、文書の語彙、役割、単位、粒度を監査する。

`dependency-analysis` は node、edge、方向、granularity を定義して依存の事実を作る。`impact-analysis` は具体的な変更を起点に、code、data、runtime、deployment、契約、所有へ伝播する影響を導く。

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
| [Matt Pocock skills](https://github.com/mattpocock/skills/tree/8b78b531ab965735c5dc74f6f7a219e1e37326df) | `bug-analysis`、`domain-modeling`、`code-design`、`module-design`、`code-review`、`tdd`、`prototype`、`web-research` |
| [Addy Osmani agent-skills](https://github.com/addyosmani/agent-skills) | `interface-design`、`code-review`、`tdd`、`bug-analysis`、`ui-design`、`performance-analysis`、security plugin |
| [WondelAI skills](https://github.com/wondelai/skills) | `refactoring`、`architecture-design`、`architecture-review`、`db-design`、`ui-review` |
| [dotnet skills](https://github.com/dotnet/skills/tree/7953ba85365219dc7df5d73634e1f9d0bfabf0b9) | `skill-creator`、`test-design`、`test-review`、`tdd` |
| [Vercel agent skills](https://github.com/vercel-labs/agent-skills/tree/b8caa260a420a73042e35521de4b5c8baf6446cc) | `component-design`、`performance-analysis`、`ui-review` |
| [Anthropic skills](https://github.com/anthropics/skills/tree/f17010c9bb483898c1d9c9f42dde2b3a98889434) | `skill-creator`、`ui-design`、`browser-review`、`description-writing` |
| [OpenAI Skills guidance](https://openai.com/academy/skills/) | `skill-creator`、routing評価、MCPを含むworkflow packaging |
| [PlanetScale database skills](https://github.com/planetscale/database-skills/tree/af0ce0cfb65cca4cc21d18ca0d9cf270ca99d488) | `db-design`、`database-review`、`migration` |
| [Supabase agent skills](https://github.com/supabase/agent-skills/tree/v0.1.8) | `db-design`、`database-review`、security plugin、`migration` |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | `code-design`、`module-design`、`refactoring`、`code-review`、`skill-creator` |
| [decomplect](https://github.com/shanev/skills/tree/main/decomplect)、Clairvoyance | `module-design`、`architecture-design`、`architecture-review`。Clairvoyanceは採用前にsourceを固定する |
| [effect-fp-skill](https://github.com/mikezupper/effect-fp-skill) | `code-design`、`data-modeling`、`error-design`。Effect固有APIは汎用規則にしない |
| [Hallmark](https://github.com/Nutlope/Hallmark)、[Impeccable](https://github.com/pbakaus/impeccable) | `ui-design`、`ui-review` |
| [japanese-tech-writing](https://gist.github.com/k16shikano/fd287c3133457c4fd8f5601d34aa817d)、[stop-ai-slop-jp](https://github.com/iKora128/stop-ai-slop-jp)、[slop-nuki](https://github.com/chezou/slop-nuki) | `ja-writing` |
| [code-humanizer](https://github.com/LeonardNJU/code-humanizer)、[deai-code](https://github.com/golovatskygroup/deai-code) | 品質判断だけを `code-review` に使い、著者推定を除く |
| [differential-review](https://github.com/trailofbits/skills/tree/main/plugins/differential-review) | security plugin |
| writing-openapi-specs | raw OpenAPIを扱う場合の `interface-design`、`interface-review` reference。採用前にsourceを固定する |

Ponytailは、削除、標準機能、既存機構、既存依存、新しい所有物の順に解決手段を問い直す。全coding taskへ強制するSkillとしては採らず、追加によって問題を解いたように見せる傾向を補正するlensとして各候補へ配る。

文章、code、UIのslopを一つのSkillへ統合しない。文章は主張と根拠、codeはcorrectnessと変更コスト、UIは利用者の仕事とinteractionを基準にする。AIらしさや著者推定のscoreは品質指標に使わない。

上流Skillを直接採用するのは、分解すると方法自体の価値を失うsignature procedureに限る。`grill-with-docs` は候補だが、薄いwrapperと依存先を含む実体、license、固定revision、compositionを採用前に確認する。

候補の発見には、次の会話記録も使った。会話内の結論は一次資料や正本ではなく、調査対象と反例を得るための入力として扱う。

- [AIらしさ、設計判断、一貫性](https://chatgpt.com/share/6a7d14a7-5ed0-83ee-9f50-a7c178a9e282)
- [Skill候補の横断調査](https://chatgpt.com/share/6a7d14b9-b444-83ee-9dbe-d6eb7458758d)
- [Matt、Addy、Web品質、WondelAI](https://chatgpt.com/share/6a7d1c95-beb8-83e8-ac31-24016faef00d)

## Skill 化の条件

候補ごとに、Skillなしの代表scenarioで不足を観測する。Skillありの同種scenarioで成果、routing、process、restraint、compositionを比較する。内容、reference、script、Skill自体を除いて結果が変わらなければ削除する。

外部sourceは採用時のrevision、license、採用理由、local modificationを追跡する。sourceの分類や作者名をruntime構造に使わない。詳細な知識は一段のreferenceへ分け、`SKILL.md` は発火後に必要なprocedureと打ち切り条件だけを持つ。
