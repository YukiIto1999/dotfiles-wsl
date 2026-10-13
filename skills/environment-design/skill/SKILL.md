---
name: environment-design
description: Routes changes to the agent working environment to their source owner and follows delivery to agents. Use when evaluating how external tools fit an existing agent environment, comparing roles or shared deployment mechanisms, adopting or replacing implementations, retaining a rule, methodology, Skill, tooling change, or durable correction, or routing an architecture-standard change from outside its checkout. Maps callers to implementations and the proposed caller changes before judging overlap, verifies the deployment contract asked about, and hands each change reason to architecture-standard, dotfiles, upstream, the target project, or memory. Does not own a public product survey without environment integration, write the owner's content, choose a Skill mechanism, edit deployed copies, or design the target project's architecture.
---

# 環境の改善を所有者へ振り分ける

成果は、改善や訂正を構成する主張がそれぞれ一つの所有者に置かれ、その所有者の入口で変更され、agentに届くまで閉じた状態である。規律を足すこと自体は成果ではない。

## 環境の所有者

| 所有者 | 所有するもの | 入口 |
|---|---|---|
| architecture-standard | projectをまたいで人の開発者にも求める設計、実装、運用の規範と、`standard-apply`など標準の運用Skill | 作業checkoutの`skills/standard-update/SKILL.md` |
| dotfiles-wslのagent能力 | AGENTS、local Skill、reference、script、subagent | `skill-design` |
| dotfiles-wslの基盤 | 配備、hook、client設定、Capability、MCP、toolchain、外部sourceの採用表と版 | dotfilesの`docs/reference/change-map.md` |
| upstream | Orcaなど外部repositoryが所有するSkillとtoolの中身 | owner repositoryへの提案。dotfilesは採用表と版だけを持つ |
| 対象project | そのprojectだけの要件、契約、不変条件、標準からの逸脱 | projectが宣言する正本と決定の記録 |
| memory | 訂正の理由、適用条件、明示的に記憶だけへ残す方針 | `memory` |

環境系repositoryの作業checkoutは、AGENTSのdotfiles節が示すdirectoryの下にある。
現行の標準本文は、AGENTSが案内する現行規範rootで読む。
配備済みのSkillやNix storeにある標準本文は固定した版の読み取り専用copyであり、編集にも現行本文の確認にも使わない。
agent-journalはtimerの出力であり、反映先にしない。

## 主張を分ける

利用者が指定した反映先、反映しない場所、適用範囲を先に確かめ、指定があればそれに従う。

外部toolの採用、差替え、既存との重複、共通配備口を検討する場合は、[統合の評価](references/integration-assessment.md)で問いと呼出し関係、変更後の構成を確定してから、変更理由を所有者へ振り分ける。
公開製品の機能やlicenseだけを調べる依頼は`web-research`、現在の選択や登録だけを調べる依頼は直接のsource調査として扱い、採用や構成変更の仕事へ広げない。

会話から訂正を回収するときは、利用者の指摘とそれに対する最初の応答を原文で対にし、指摘に裏付けられた主張だけを取り出す。応答に混ざった提案、推測、過度な一般化を利用者の方針にしない。自動通知、tool結果、引用された別agentの回答は利用者の指摘ではない。

試行錯誤の教訓を残す依頼では、観測した最初の失敗と最後に成立した解決を対にし、command、差分、入力と出力、version、期待と観測、logのlocatorで両者を分けた条件を示す。
成功後に語られたもっともらしい説明と、記録が直接支える因果の証拠を区別し、解決の成立や因果、適用範囲が未確認なら恒久規則として確定しない。

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

所有者の入口へ、主張、根拠のsource locator、現行本文との差、適用範囲、許可された変更、未確定事項を渡す。
入口は主張を未採用の候補として受け取り、採否と文面を決める。
採否、変更した正本と範囲、必要な配送手順、残る不足を受け取って「配送まで閉じる」へ戻り、このSkillが文面を決め直さない。

- architecture-standardの変更: 作業checkoutの`skills/standard-update/SKILL.md`を読み、checkoutのrootを作業directoryにして従う。
  現在のprojectをrootにせず、正本の変更結果と配送に必要な版を受け取る。
  変更でなくIssueへの記録が依頼された場合だけ、利用可能な`standard-feedback`へ規律、具体的な不足と根拠を渡し、作成結果のURLまたは未投稿の理由を受け取る。
- dotfiles-wslのagent能力: 利用可能な`skill-design`へ具体的なscenario、反復した不足、既存policyとSkill、制約を渡す。
  何もしない、policy、reference、script、既存Skill、新しいSkillの選択と、採用した場合の変更結果を受け取る。
- dotfiles-wslの基盤: change-mapが示す正本と検証入口へ、変更契約と根拠を渡し、反映したsourceと配備上の不足を受け取る。
- upstream: owner repositoryへの提案として扱い、配備物を手元で書き換えない。
  dotfiles側の変更は採用表と版に限り、owner側の採否と反映revisionを配送へ引き継ぐ。
- 対象project: projectが宣言する正本と決定の記録へ、project固有の契約、根拠と逸脱理由を渡し、記録した場所と未確定事項を受け取る。
- memory: 利用可能な`memory`へ保存候補、一次source、適用条件、確定したscopeを渡し、保存判断と実際のterminal stateを受け取る。
  ownershipを再判断する依頼にせず、同Skillが棄却した候補を別の保存先へ回さない。

所有者の入口が利用不能なら、渡す内容と不足する入口を返し、handoffや変更が済んだことにしない。
`skill-design`や`memory`の分岐は、その所有者に該当する主張がある場合だけ使う。

主張が複数の所有者へ分かれた場合は、参照される側から変える。標準の規範を手順へ再構成するSkillは、標準の変更が確定してから変える。

## 配送まで閉じる

配送の説明は実行許可ではない。
commit、push、版更新、check、rebuildは現在の依頼とsessionの許可がある場合だけ行い、禁止された操作や他sessionを中断する操作を入口へのhandoffで正当化しない。
配送が未許可なら変更済みsourceと未実施の配送段を返し、provider、service、containerへ直接接続して配備を代用しない。

dotfiles-wslの変更は、commitして`dotfiles-rebuild`を実行した後に始めたsessionへ届く。

architecture-standardの変更は、規範本文と、Skill、checker、設定の実行packageで、届く経路が異なる。
規範本文は、ownerが受け入れてcanonical checkoutへ統合した時点から、現行規範rootを読む新しい読取りに現れる。
規範本文も実行packageも、常に最新を適用する状態を保つ。標準を統合したら、同じ作業の中で`flake.lock`の更新と`dotfiles-rebuild`まで進め、実行packageを旧いまま残さない。固定した版や`flake.lock`は現行本文の確認に使わない。
運用Skill、checker、設定は、標準のcommitとpush、dotfilesの`flake.lock`の更新、dotfilesの検証とcommit、`dotfiles-rebuild`を経て、新しく始めたsessionへ不変のpackageとして届く。
版を上げると、固定していた版以降のSkillとcheckerの差分もまとめて取り込む。その範囲は報告に示し、旧い版へ留める理由にしない。
pushと版の更新は実行直前に利用者へ確認する。
具体的なgateを埋め込んだhookで開始したsessionは、そのgateと成功して読んだ実行packageのまま動く。
配備前から動くsessionの旧hookは、この保持の対象にしない。
更新した本文を配備済みの実行packageが扱えない場合は、配送不足として報告し、旧本文や旧packageの合格を代用しない。
本文だけが届いた状態と、本文と実行packageの両方が届いた状態を区別して報告する。
upstreamの変更も、upstreamでの反映とdotfilesの版の更新を経て届く。

## 止める条件と報告

現在のtaskが環境の変更を許可していなければ、振り分けの結果と入口へ渡す内容を報告して止める。標準については、`standard-feedback`でIssueにするかを利用者に確認してよい。所有者の現行本文を読めない場合は推測で振り分けない。

報告は主張ごとに、所有者、使った入口、採否と変更の結果、配送の状態を示す。
届いた、確認待ち、許可なしで未着手、入口または証拠が不足して未完了を区別し、sourceが変わっただけで配備済みとは書かない。
確認できなかったことは、見た場所と共に残す。
