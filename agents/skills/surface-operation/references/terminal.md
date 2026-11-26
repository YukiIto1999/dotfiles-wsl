# CLI/TUIのrouteと操作

## Routeを選ぶ

利用者が実際に使う入力方法に合わせて選ぶ。
TTYの有無で出力、色、prompt、確認の挙動が変わる契約なら、両方を別の行にする。

| 順 | route | 使う条件 |
|---|---|---|
| 1 | clientのshell toolで、このSkillが起動する非対話のprocess | 保証がargv、stdin、環境、exit code、stdoutとstderr、生成物で決まり、TTYに依存しない |
| 2 | clientのPTYを持つterminal toolで、このSkillが起動するprocess | TTYの判定、key入力、prompt、全画面の描画、resize、signalに依存する |
| 3 | なし | 必要なPTYをclientが公開していない、または対象が利用者や他のagentの既存のterminalにある |

PTYの有無と使い方は現在のtool schemaで確かめ、schemaにない入力方法を推測しない。
利用者や他のagentの既存のterminal、multiplexerのsession、実行中のprocessへ、入力の注入、attach、debuggerの接続をしない。
Orcaのterminalやworktreeの管理は`orca-cli`の仕事であり、このrouteの代わりにしない。

## 安全に起動する

- 対象checkoutと、projectが定める開発環境の入口（devShellやproject runner）で起動する。
  起動に開発serverや依存serviceが必要なら、`local-development`から使える状態と所有者を受け取る。
- 利用者のhome、設定file、credential store、共有cacheへ書く可能性があるcommandは、対象projectや対象CLIの文書が用意する設定directory、profile、fixtureで隔離できる場合だけ実行する。
  隔離できなければ、その書込みを外部結果として扱い、明示の許可がなければ確定前で止める。
- 終わらないprocessには上限時間を付け、常駐するprocessは自分の起動として識別値を記録し、終了まで追跡する。
- secretを引数、画面、transcriptへ出さず、passwordなどのpromptへ実際のcredentialを入力しない。

## 操作と観測

- 非対話のprocessでは、argv、cwd、結果に関係する環境変数の名前、stdin、exit code、stdoutとstderrを分けて記録し、契約が生成物や状態の変化を持つ場合はそれも確かめる。
- PTYでは、行数と桁数、`TERM`、localeを記録し、promptや期待する文言の出現を待ってから次のkeyを送る。
  resize、画面の切替、再描画の後は画面を読み直してから次の入力を決める。
- PTYはstdoutとstderrを一つの流れにまとめ得る。
  分けて判定する必要がある主張は、route 1の行で確かめる。
- toolが制御sequenceを含む生の出力しか返さない場合、描画後の配置、色、欠け、重なりはその出力から推測せず、描画された画面を得られない行を未確認にする。
- Ctrl-Cなどの中断やsignalの扱いが受入条件なら、PTYから通常のkeyで送り、終了状態と後に残る状態を確かめる。

## 証拠

screenshotの代わりに、各checkpointの描画後の画面またはstdoutとstderrを、入力列とexit codeを添えたtranscriptとして本文の保存先へfileで残す。
長い出力は判定に必要な範囲を残し、省いた範囲を明記する。

## 閉じる

このSkillが起動したprocessとその子processだけを終了し、終了したことを確かめる。
作成した一時fileや隔離用のdirectoryは、保存先へ残す証拠を除いて回収する。
