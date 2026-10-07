# Fresh実行の契約

このreferenceは評価を起動するtop-levelが使う。
APIの有無、引数、返却値は現在の公開schemaで確認し、以下の例にある操作名が公開されていなければ呼び出さない。
子はscenarioを実行して返すだけにし、評価のdispatchと集約を親へ残す。

## 実行記録を用意する

実行前に割り当て済みの`local://`または評価用directoryへ、次の対応を保存する。
秘密情報や不要な会話をfixtureへ含めない。

| 項目 | 残すもの |
|---|---|
| 評価のidentity | 対象sourceのpathと版、評価版、iteration、scenario、trial、mode、対照か候補か |
| 入力 | 利用者のtask、必要なsource bundle、制約、初期状態、許可された副作用 |
| 判定 | criterionのID、critical、達成の証拠、holdoutの区分、反復回数、停止条件 |
| 環境 | 要求したmodelとthinking、実際に解決したmodel、policy、利用可能なtoolとSkill、preload |
| 実行結果 | request、返却結果、成果物、自己申告、tool記録、error、truncation、artifactのlocator |
| 比較条件 | 差にした一要素、揃えられなかった条件、測れない項目 |

holdout、採点専用のrubric、対照以外の候補、失敗台帳は実行者から隠す。
native taskの子は親と`local://`のrootを共有するため、fileを渡さないだけで読めない状態になったと主張しない。
候補、期待解答、過去の成果が共有workspaceや履歴から読める場合も、漏洩の可能性を比較条件へ記録する。

## Method-onlyのfresh completion

toolなしで完了できるtaskには、公開されたOMP `eval`の`completion()`を使える。
これはstatelessな一回のmodel completionであり、native Skillの発火やtoolの実行ではない。
`eval`が公開されているtop-levelだけが、現在のschemaとhelperの契約を読んで使う。

JavaScriptの公開形は`completion(prompt, { model, system, schema })`で、handleの`wait()`が結果を返す。
`model`は`default / smol / slow`のtierを指定する値であり、native taskの具体的なmodel selectorとは別の契約である。
明示した固定`system`、task、必要な入力だけで一回ずつ呼び出し、会話履歴をpromptへ貼らない。
対照には候補の名前、description、本文、reference、候補から作った解答を含めず、候補側だけに対象本文と必要なreferenceを明示する。
改訂の比較では対照側へ現行版を渡し、候補側へ改訂版を渡す。
報告の依頼やtaskに本来ある受入条件は両側で揃える。

既に親が用意した`fixedSystem`、`baselinePrompt`、`candidatePrompt`を使う最小の呼出しは次の形になる。

```js
const baseline = completion(baselinePrompt, { model: "default", system: fixedSystem });
const candidate = completion(candidatePrompt, { model: "default", system: fixedSystem });
display({ baseline: await baseline.wait(), candidate: await candidate.wait() });
```

値は事前の記録から親が用意し、作者の修正意図や評価結果を混ぜない。
各trialで新しいhandleを作り、completionへ渡していない環境の能力を利用したことにしない。
失敗したcompletionはerrorとして残し、空の解答や仮の成功で代用しない。
実modelのmetadataが取得できない場合は要求したtierだけを記録し、modelを揃えた比較かは未確認とする。
このmodeの成果を、full-environmentの改善量や自然発火率へ読み替えない。

## 実toolと自然発火のnative task

実toolが必要なscenarioは、top-levelに公開されたnative `task`で一scenario、一trial、一agentとして起動する。
現在のschemaにbatch形がある場合は`context`と`tasks[]`を使い、各itemへ`task`と`solutionSpace`を渡す。
flat形だけなら一件ずつそのschemaで呼ぶ。
共通`context`はtaskの背景と権限だけにし、候補の使い方、採点専用の基準、作者の会話を入れない。
`solutionSpace`は許された判断の自由度を記述し、選ぶべきSkillや解答を教えない。
agentの定義、tools、preload、modelを読むことで、専門agentの隠れた指示を比較条件へ含める。

自然発火を測るtrialでは対象本文を注入せず、Skillが通常のdiscovery経路で利用可能な状態にする。
実行記録で対象の`SKILL.md`を読み込んだかを観測し、本文をpreloadしていたtrialは自然発火の標本から外す。
Skill名が最終回答にあるだけでは発火の証拠にならない。
実際のtool名、入力、返却結果と、その結果を使った成果を保存する。
Capabilityが使えない枝では、独立した成果と未取得の証拠を分ける挙動を測り、返却結果をmockで補わない。

native taskは会話履歴を継承しなくても、workspace、Skill、context file、親の共有artifactや設定の影響を受ける。
`isolated: true`はworkspaceの分離であり、Skillやpolicyを除いたbaselineの指定ではない。
`tools`は親のeval kernelで定義したtoolの公開指定であり、組込みtoolやSkillを除くallowlistとして使わない。
workspace隔離が必要なら、現在のschemaと実行設定で副作用、patchの適用、branch操作を先に確認する。
変更を禁止されたrepositoryの代わりに、許可済みの評価用workspaceを使う。
親から同じagentへメッセージを送り再開した結果は、fresh trialとして数えない。

候補を除いたfull-environment対照を作るには、discovery一覧、preload、policyの候補への導線、共有fileを含めて除外を確かめる必要がある。
公開APIでその状態を制御できない場合は「no-skill baseline未測定」と返す。
現在の環境の候補ありtrialは実行できるが、子への「候補を使わない」という指示で候補なしの初期状態を偽装しない。
別のprofileやCLIを起動する方法は、このreferenceから権限を追加する代替手段にしない。

## 返却証拠を読む

native taskの完了後に返ったscenarioごとの`SingleResult`があれば、その値を使う。
開始時のbackground通知やbatch全体の`totalDurationMs`を、一scenarioの完了結果と混同しない。

| 指標 | 許される出典 | 欠けた場合 |
|---|---|---|
| 所要時間 | 完了した個別結果の`durationMs`、または計測区間を固定した親の実測clock | 未測定とする |
| tool-call数 | 完全なtraceのtool-call entryを一件ずつ数えた値 | 未測定とする |
| provider usage | 返却された`usage`の実fieldと意味 | fieldを作らない |
| 実model | `resolvedModelIdentity`、`resolvedModel`、`resolvedThinkingLevel`、fallback情報など返却された値 | 要求値と実際の値を区別する |
| 再判断の回数 | 実行者の自己申告と理由 | 未申告とする |
| 発火 | preloadされていない対象本文を実行記録で読み込んだ証拠 | 未確認とする |

tool-call数にはRead、Grep、失敗した呼出しも含め、並列wrapperの数でなく個々の呼出しを同じ規則で数える。
traceが部分的なら見えている件数を下限と表示し、完全な操作数として比較しない。
`history://<id>`の簡略表示に全tool-callがあるとは限らないため、数えるときは完全な保存traceを使う。
model request数、token数、自己申告の判断回数をtool-call数へ置き換えない。
親のclockを使う場合はqueue、起動、tool待ちを含むwall-clockとして名前を付け、runtime metadataの時間と混ぜない。

成果物、自己申告、`agent://<id>`の全出力、必要な保存traceを結び付け、criticalの判定ごとに証拠を示す。
Causeは原因仮説として扱い、外から確認できるIssueと分ける。
不足する証拠やAPIによって閉じない評価は、未測定の項目と親が必要とする入力を返して終了する。
