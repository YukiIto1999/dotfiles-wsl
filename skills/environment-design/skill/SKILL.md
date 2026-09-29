---
name: environment-design
description: Decides which owner in the agent working environment receives an improvement, lesson, or durable correction, hands each part to that owner's entry, and follows it through delivery to agents. Use when a rule, methodology, Skill, tooling change, or correction should outlive the current task and its owner among architecture-standard, dotfiles agent capability, dotfiles infrastructure, an upstream source, the target project, or memory is not yet fixed, or when architecture-standard must change from a session outside its checkout. Splits mixed claims by change reason, reads the owner's current text before adding anything, and chains to standard-update in the standard checkout or to skill-design. Does not write the owner's content, choose a Skill mechanism, edit deployed copies, or design the target project's architecture.
---

# 環境の改善を所有者へ振り分ける

成果は、改善や訂正を構成する主張がそれぞれ一つの所有者に置かれ、その所有者の入口で変更され、agentに届くまで閉じた状態である。規律を足すこと自体は成果ではない。

## 環境の所有者

| 所有者 | 所有するもの | 入口 |
|---|---|---|
| architecture-standard | projectをまたいで人の開発者にも求める設計、実装、運用の規範と、`standard-apply`など標準の運用Skill | 作業checkoutの`.claude/skills/standard-update/SKILL.md` |
| dotfiles-wslのagent能力 | AGENTS、local Skill、reference、script、subagent | `skill-design` |
| dotfiles-wslの基盤 | 配備、hook、client設定、Capability、MCP、toolchain、外部sourceの採用表と版 | dotfilesの`docs/reference/change-map.md` |
| upstream | Orcaなど外部repositoryが所有するSkillとtoolの中身 | owner repositoryへの提案。dotfilesは採用表と版だけを持つ |
| 対象project | そのprojectだけの要件、契約、不変条件、標準からの逸脱 | projectが宣言する正本と決定の記録 |
| memory | 訂正の理由、適用条件、明示的に記憶だけへ残す方針 | `memory` |

環境系repositoryの作業checkoutは、AGENTSのdotfiles節が示すdirectoryの下にある。配備済みのSkillやNix storeにある標準本文は固定した版の読み取り専用copyであり、編集にも現行本文の確認にも使わない。agent-journalはtimerの出力であり、反映先にしない。

## 主張を分ける

利用者が指定した反映先、反映しない場所、適用範囲を先に確かめ、指定があればそれに従う。

会話から訂正を回収するときは、利用者の指摘とそれに対する最初の応答を原文で対にし、指摘に裏付けられた主張だけを取り出す。応答に混ざった提案、推測、過度な一般化を利用者の方針にしない。自動通知、tool結果、引用された別agentの回答は利用者の指摘ではない。

一つの主張が一つの変更理由だけを持つまで分ける。方法論は、何を満たせば正しいかという規範と、agentがそれをどう再現するかという手順、打ち切り条件、失敗例、toolの経路とに分かれることが多い。この二つは別の主張として扱う。

## 所有者を決める

主張ごとに次の順で問い、最初に当てはまった所有者を選ぶ。

1. 特定のprojectだけに成り立つか。成り立つなら対象project。標準から外れる採用なら、そのprojectの決定の記録に置く。
2. agentの有無によらず、projectをまたいで人の開発者にも求める設計、実装、運用の規範か。標準のREADMEが定める領域のいずれかに置けるなら、architecture-standardの本文。
3. agentの行動、成果物の形式、作業手順に関わるか。関わるなら、変える対象のpolicyやSkillを所有するrepository。AGENTSとlocal Skillはdotfiles-wslのagent能力、`standard-apply`など標準の運用Skillはarchitecture-standard、Orcaの操作Skillはupstreamが所有する。
4. 配備、実行基盤、hook、client、外部sourceの採用と版に関わるか。関わるならdotfiles-wslの基盤。
5. 理由と適用条件を記憶として残すだけか。それならmemory。

どの所有者にも当てはまらない主張は、新しい置き場を作らずに未決として報告する。所有者の選択が利用者の意図に依存する場合、たとえば標準を改訂するかprojectの逸脱にするか、projectとglobalのどちらに適用するかは、一度だけ確認する。

所有者を選んだら、その所有者の現行本文を作業checkoutで読む。既存の記述が主張を満たしていれば規律を増やさない。問題が起きた原因を、読まれなかった、適用されなかった、範囲を誤読された、のどれかに分け、原因のある箇所の所有者へ振り分け直す。読まれなかった原因がSkillのdescriptionやpolicyからの導線にあるなら、そのSkillやpolicyの所有者が受け取る。同じ訂正が文面の追加の後にも再発しているなら、文面ではなく、適用を強制する検査やhookの所有者を選ぶ。

同じ主張は一つの所有者にだけ置く。他の所有者は参照するか、手順へ再構成し、本文を複製しない。

## 入口へ渡す

所有者の入口へ、主張、根拠のsource locator、現行本文との差、未確定事項を渡す。入口は主張を未採用の候補として受け取り、採否と文面を決める。このSkillは文面を決めない。

- architecture-standard: 作業checkoutの`.claude/skills/standard-update/SKILL.md`を読み、checkoutのrootを作業directoryにして従う。現在のprojectをrootにしない。利用者が変更でなく記録だけを求めた場合は`standard-feedback`でIssueにする。
- dotfiles-wslのagent能力: `skill-design`で、何もしない、policy、reference、script、既存Skill、新しいSkillのどれにするかを決める。
- dotfiles-wslの基盤: change-mapが示す正本と検証入口に従う。
- upstream: owner repositoryへの提案として扱い、配備物を手元で書き換えない。dotfiles側の変更は採用表と版に限る。
- 対象project: projectが宣言する正本と決定の記録に置く。
- memory: `memory`の保存判断に従う。sessionに`memory`がなければ所有者の候補から外す。

主張が複数の所有者へ分かれた場合は、参照される側から変える。標準の規範を手順へ再構成するSkillは、標準の変更が確定してから変える。

## 配送まで閉じる

dotfiles-wslの変更は、commitして`dotfiles-rebuild`を実行した後に始めたsessionへ届く。

architecture-standardの変更は、標準のcommit、push、dotfilesの`flake.nix`にある`architectureStandard`の版と`flake.lock`の更新、dotfilesの`nix flake check`とcommit、`dotfiles-rebuild`を経て初めて届く。版を上げると、固定していた版以降の標準の改訂もまとめて取り込むため、その範囲を利用者に示す。pushと版の更新は実行直前に利用者へ確認する。版を更新するまでは、配備済みのagentが旧版の標準を適用し続けるため、届いたと報告しない。upstreamの変更も、upstreamでの反映とdotfilesの版の更新を経て届く。

## 止める条件と報告

現在のtaskが環境の変更を許可していなければ、振り分けの結果と入口へ渡す内容を報告して止める。標準については、`standard-feedback`でIssueにするかを利用者に確認してよい。所有者の現行本文を読めない場合は推測で振り分けない。

報告は主張ごとに、所有者、使った入口、変更の結果、配送の状態を示す。配送の状態は、届いた、利用者の確認待ち、許可なしで未着手のいずれかにする。確認できなかったことは、見た場所と共に残す。
