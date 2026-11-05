---
name: environment-design
description: Routes changes to the agent working environment to their source owner and follows delivery to agents. Use when evaluating how external tools fit an existing agent environment, comparing roles or shared deployment mechanisms, adopting or replacing implementations, retaining a rule, methodology, Skill, tooling change, or durable correction, or routing an architecture-standard change from outside its checkout. Maps callers to implementations and the proposed caller changes before judging overlap, verifies the deployment contract asked about, and hands each change reason to architecture-standard, dotfiles, upstream, the target project, or memory. Does not own a public product survey without environment integration, write the owner's content, choose a Skill mechanism, edit deployed copies, or design the target project's architecture.
---

# 環境の改善を所有者へ振り分ける

成果は、改善や訂正の根拠を確かめ、必要な変更だけを所有者の入口で扱い、許可された配送まで閉じた状態である。
既存の内容で足りる場合は、変更しない判断を返す。

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

変更理由と現行の正本を、上の所有者表へ対応付ける。
既存のpolicy、Skill、基盤を変える主張は、その正本の所有者を優先し、dotfiles内の変更を「一つのprojectだけ」という理由で対象projectへ送らない。
新しい規範については、人の開発者にもprojectをまたいで求めるものか、そのprojectだけの要件や逸脱かを分ける。
所有者の選択が利用者の意図に依存し、既存の契約から決められない場合だけ確認する。

所有者候補の現行本文と、それを呼び出す指示を読み、主張を満たす記述、重複、矛盾を照合する。
既存の規律で足りるなら同じ規律を増やさず、実行記録から、導線、適用条件、指示の衝突、実行手段のどこに不足があるかを調べる。
原因を特定できない場合は仮説として残し、判断を分ける観測を示す。
追記後の再発だけで検査やhookを選ばず、原因と現行本文との差を所有者の入口へ渡し、修正、削除、手段の変更を比較させる。
agentの方法は`skill-design`が選び、決定的な検査が必要と判断された場合は、その検査を所有する基盤へ渡す。

同じ主張は一つの所有者に置き、他の所有者は参照するか手順へ再構成する。

## 入口へ渡す

所有者の入口へ、主張、根拠のsource locator、現行本文との差、適用範囲、許可された変更、未確定事項を渡す。
入口が採否と文面を決め、変更した正本、検証結果、配送に必要な条件を返したら「配送まで閉じる」へ進む。
所有者が確定済みの主張を振り分け直したり、入口の判断をこのSkillでやり直したりしない。

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

複数の所有者へ分かれた変更は、参照される契約を先に確定する。

## 配送まで閉じる

配送の説明は実行許可ではない。
commit、push、版更新、check、rebuildは現在の依頼とsessionの許可がある場合だけ行い、禁止された操作や他sessionを中断する操作を入口へのhandoffで正当化しない。
配送が未許可なら変更済みsourceと未実施の配送段を返し、provider、service、containerへ直接接続して配備を代用しない。

dotfiles-wslの変更は、sourceを検証してcommitし、同repositoryの`docs/operations/rebuild.md`に従ってplan、適用、実状態の確認へ進める。
sourceの変更と配備、新しいsessionへの反映は別の状態として確認する。

architecture-standardの規範本文は、ownerがcanonical checkoutへ統合した後、その現行規範rootを読む新しい読取りに現れる。
Skill、checker、設定の実行packageは、標準のcommitとpush、dotfilesの`nix flake update architectureStandard`と`flake.lock`のcommit、検証とrebuildを経て新しいsessionへ届く。
標準を統合したら同じ作業で実行packageも最新へ更新し、前回の更新以降に取り込む差分の範囲を報告する。
pushは実行直前に確認し、許可済みの版更新やcommitを再確認で止めない。
固定した版やlockは現行本文の代わりにせず、本文だけが届いた状態と実行packageも届いた状態を区別する。
更新した本文を配備済みのpackageが扱えない場合は配送不足とし、旧本文や旧packageの合格を代用しない。
upstreamの変更も、owner側での反映とdotfilesの採用版更新を経て届ける。

## 止める条件と報告

現在のtaskが環境の変更を許可していなければ、振り分けの結果と入口へ渡す内容までを返す。
所有者の現行本文や入口を利用できない場合は、その主張の判断や変更だけを保留し、読めた正本で独立に判断できる範囲を返す。

報告は主張ごとに、所有者、使った入口、採否と変更の結果、配送の状態を示す。
届いた、確認待ち、許可なしで未着手、入口または証拠が不足して未完了を区別し、sourceが変わっただけで配備済みとは書かない。
確認できなかったことは、見た場所と共に残す。
