---
name: github-operations
description: Carries out GitHub requests using the available GitHub MCP, gh, or Git. Use for repositories, issues, pull requests, reviews, branches, releases, and Actions runs. Confirms the acting account and exact target, checks the result, and resolves uncertain writes before retrying. Not for local repository research, judging reviews, or configuring credentials.
---

# GitHub上の操作を安全に実行する

依頼された結果を、確定したアカウントと対象で実現する。依頼にない書き込みや通知を付随して行わない。

## 公開操作を解決する

アカウント別の共有Gatewayでは `github-<account>` が同じ主体の読み書きを提供する。例えば `mcp__gateway_github_account_1_get_me` は `github-account-1` の `get_me` である。公開されたtool一覧・schemaを確認し、依頼の入力を表せる操作を選ぶ。

| 目的 | 選択と確認 |
|---|---|
| リポジトリの作成や fork | owner、名前、作成先の公開範囲を確かめる。MCP `create_repository`／`fork_repository` または `gh repo create`／`gh repo fork` を使い、作成先の ID、canonical URL、可視性や fork 元を読む。リモート作成の依頼だけなら local remote は変えず、push もしない。 |
| Issue・PR・レビュー | MCP か `gh` で対象と現在の状態を読む。関連付け、作成時のフィールド、draft、保留中のレビュー、リアクションなど、依頼された入力を扱える操作を選ぶ。初期ラベル付きの Issue を一操作で作成できるなら、作成と更新に分けない。 |
| Actions の診断 | 対象 SHA を確定し、MCP の `actions_list`／`actions_get`／`get_job_logs` または `gh run list`／`gh run view` で、run・job・log を照合する。実行開始や再実行は読み取りと区別し、依頼されたときに `gh` で行う。 |
| Git の ref や履歴 | 実際の remote URL と ref を Git で確定する。GitHub の状態を変更する場合は、確認対象の ref と SHA を固定する。 |

表は例であり、操作の一覧ではない。MCPに該当操作がなければ、同じ主体の `gh`（専用subcommand、次いで公式APIを呼ぶ `gh api`）や Git を使う。CLIで入力を表せない場合はMCPも調べる。未公開のtoolとGitHubの権限不足は区別する。

`gh` で別アカウントを使う場合は、サブシェルで継承した `GH_TOKEN`、`GITHUB_TOKEN`、`GH_HOST` を外し、`gh auth token --hostname github.com --user "$login"` の結果をコマンド置換で受ける。値を表示せず `GH_TOKEN` としてそのサブシェルの子プロセスにだけ渡し、`GH_HOST=github.com` を指定する。書き込み前に同じ環境の `gh api user --jq .login` が選んだ login と一致することを確かめる。HTTPS の Git は対象 owner に対応する[既存の credential 設定](../../../docs/operations/secrets.md#github-account)を使う。

## identityとtargetを固定する

1. 依頼と既存contextから、`account target`、実行主体のGitHub login、`owner/repo`、issueまたはPRの種別と番号、対象branchを取り出す。branch間の操作ではheadとbaseを区別する。
2. 完全修飾された指定、canonical URL、選択済みrepositoryやbranchのcontextを優先する。複数の根拠が食い違う場合は、一方を黙って採用しない。
3. 足りない値だけをread-only lookupで補う。候補account targetのidentityは`get_me`相当のreadで確認し、repository、issue、PR、branchはexact lookupの返り値で存在、種別、canonical owner/nameを確定する。広い一覧や曖昧なtitle検索は、exact lookupへ絞るために必要な場合だけ使う。
4. `account target`はresourceの`owner`とは別に固定する。明示された実行identityと一致するtargetを使い、明示がなければ既存contextとread結果から一意になるtargetだけを選ぶ。複数accountが同じ操作を行えることは選択理由にならない。
5. 書き込みには事前照合で確定した同じ主体を使う。MCP・`gh`・Gitの間で手段を替える場合も、対象と実行loginを保持する。

対象または実行identityが一意にならない場合は、候補と曖昧な項目を示して止める。lookupのためにbranch、comment、draft reviewなどを作成してはならない。
「職場」「個人」などは依頼者の呼称であり、target番号、Gitの既定identity、`owner/repo`、過去の利用頻度からloginを決めない。呼称とloginを対応付ける根拠がなければ、`get_me`で確認した候補から依頼者に実行loginを選んでもらう。

## readとwriteを分ける

依頼を、GitHub上で成立させるpostconditionと、許可された副作用へ分解する。情報取得とtarget解決はreadであり、remote state、可視性、通知、履歴を変える呼出しはwriteとして扱う。

書き込み前に、選んだ主体で対象の現状を読む。対象が新規なら作成先のowner・repositoryと同名の対象の有無を、更新なら関連するフィールドや状態を、refならexact refとhead SHAを確かめる。読めないことを不存在とみなさない。

現stateと依頼されたpostconditionを比較し、すでに成立していればwriteせずno-opとして返す。成立していない場合も、依頼された差分だけを一度実行する。例えば、PR作成からbranch作成を、comment追加からreactionやcloseを、field更新から別fieldの整形を推測して追加しない。複数の副作用を含む依頼では、それぞれが明示されていることを確認する。

write後は、返り値が新しいstate、ID、URL、またはSHAを確定しているか確認する。不足する場合だけexact resourceを再読する。確認できない成功を成功済みとして扱わない。

## merge、delete、履歴変更を確認する

merge、resource・file・branchのdelete、commitを生成するcontent変更、branchのheadまたはhistoryを動かす操作は、実行直前にユーザーの明示確認を得る。最初の依頼にその操作が含まれていても、直前確認の代わりにはしない。

確認には次を一度に示す。

- account targetと実行login
- 完全修飾した`owner/repo`と対象issue、PR、file、branch
- 実行する操作と、削除範囲、merge方法、historyへの効果など不可逆な差分
- pre-readで得た関連stateとexact SHA、および期待するpostcondition

確認後、writeの直前に同じ対象を再読する。state、head/base、対象範囲が確認時から変わっていれば確認を無効とし、新しい差分を示して再確認する。変化がなければ、確認された一操作だけを実行する。

## idempotencyと再試行

- 各writeはtarget、変更前state、postconditionの組として扱う。更新は可能なら直前に読んだstateまたはSHAをpreconditionにする。
- timeout、接続切断、5xxなどで書き込み結果が不明な場合は、手段を替えて直ちに再送しない。exact resourceを読み、postcondition、新しいID、commit、comment、reviewなど前回の効果を確認する。
- 効果が確認できれば再試行せず成功として確定する。実行されていないと証明でき、preconditionも変わっていない場合だけ同じwriteを一度再試行できる。証明できなければ重複を避けて止め、結果が不明であることを報告する。
- 新しいresourceを作るwriteは、同じtitleや本文でも別resourceになり得る。titleや本文の一致だけで同一性を決めず、返却されたID・URL、対象、実行identity、head/baseなど、その操作を一意にする値で確認する。
- conflictやstale stateでは再読して差分を作り直す。確認対象のmerge、delete、historyが変わるなら、再試行前に改めて確認を得る。writeを並列送信しない。

## 隣接Skillへ引き渡す

PR本文、changelog、release noteの作成が必要なら、利用可能な`technical-writing`へ成果物、読者、exactな差分範囲、issue、互換性と実行済み検証を渡し、確定した変更説明を受け取る。
commit済み差分のreviewが必要なら、`code-review`へ利用者が指定したfixed pointとHEADのSHA、`git diff <fixed-point>...HEAD`で表す範囲、spec sourceと標準sourceを渡し、StandardsとSpecの所見を受け取る。
そのcommitted-range契約をstaged・unstaged差分のreviewや、approve、comment、request changesの判断へ広げない。
reviewの送信種別は利用者の指定または明示的に委ねられたreview判断から確定する。
commit messageが必要で、同じ変更を表す既存のstaged diffがある場合だけ、`commit-writing`へrepositoryとそのstaged diff、policyを渡し、検査結果を伴うmessageを受け取る。
remote contentだけの変更をローカルのstaged diffとして扱わない。本文・message・判断がすでに確定している場合はその内容を使う。作成も依頼された場合は、利用できる手段で必要な根拠を集めて作成する。専門Skillの有無をGitHub操作の前提にしない。

handoffを理由に、identity確認、pre-read、直前確認を省略しない。

nuget.orgへ公開するpackageのOIDC設定、API keyからの移行、`NuGet/login`が主題なら、利用可能な`nuget-trusted-publishing`へpackage、公開workflow、repositoryと実行identity、現在の認証方式、許可された変更を渡す。
認証契約、必要なworkflow変更、移行の検証結果を受け取り、一般のGitHub releaseやprivate feedの依頼を同Skillへ広げない。
workflowやsecretの反映、release実行が明示的に依頼された場合だけ、確定した成果を同じaccount targetと直前確認の手順へ戻す。
利用できる手段と許可で完了できない場合は、足りない権限や未実施の操作を返す。

## 安全に報告する

実行account targetとlogin、完全修飾したtarget、行ったreadまたはwrite、変更前stateを識別する値、結果のID・URL・state・SHAを必要な範囲で報告する。writeしなかった場合は、no-op、権限不足、未確認、または結果不明を区別する。再試行した場合は、最初の結果をどうreadで判定したかも示す。

API responseまたは結果確認で裏付けられた範囲だけを成功として述べる。credential、token、不要なprivate content、raw request/response全体は出力しない。

## 打ち切り条件と対象外

次の場合はwriteせず、確定できた事実と不足する判断を返す。

- account target、実行login、`owner/repo`、resource種別・番号、またはbranchが一意でない
- 作成先や変更前の状態が不明で、書き込む対象や内容を確定できない
- 依頼された副作用と現在のpostconditionが対応しない
- merge、delete、history変更の直前確認がない、または確認後に対象stateが変わった
- 先行writeの成否をreadでも確定できず、安全な再試行を証明できない

GitHub MCPのAPI一覧やparameter catalog、local repositoryの調査、diffの評価、変更説明・review判断・commit messageの作成、credential設定は対象外である。`gh auth login`と`gh auth switch`は実行しない。認証失敗や権限不足は、accountを切り替えて回避せず、そのidentityとtargetに対する失敗として報告する。
