---
name: ui-design
description: Design UI before implementation, or evaluate and redesign an existing UI from observation evidence. Choose information structure, visual hierarchy, interactions, recovery, responsive behavior and accessibility from user tasks and real content. Treat the existing design system as revisable when redesign is requested. Not for browser operation, accessibility certification, component architecture, frontend coding or bug diagnosis.
---

# 利用者の仕事からUI briefを作る

成果は画面部品の一覧ではない。利用者が目的を達成する順序と、各操作に対する画面の応答を、実装前に判断できるUI briefである。既存UIの評価や再設計が明示された場合は、渡された観測証拠から設計上の問題と代替案を判断できるbriefにする。

## 現在の文脈を確認する

productの目的、利用者、利用場面、主要task、実データと値の範囲、表示文言、端末、入力方法、技術上と運用上の制約を確認する。repositoryがある場合は、既存画面、design system、token、shared primitive、content規約、accessibility要件を先に読む。
実装済みsurfaceの状態や実contentが設計判断を変える場合だけ、利用可能な`browser-operation`へURL、観測するtaskとstate、viewport、許可されたaccountと操作を渡す。
返されたsnapshot、必要なappearanceの証拠、未確認事項を設計入力へ戻し、観測を理由に設計やaccount変更を委ねない。
呼び出し側が観測結果をすでに渡している場合は、それを入力として使い、同じ観測を依頼し直さない。
repository内のdesign system、token、shared primitiveの所在や関係が不明な場合だけ、利用可能な`repository-research`へroot、問いと既知のanchorを渡し、source locator付きの関係と制約を受け取る。
どちらもこの設計方法を始める必須条件ではなく、利用不能ならその観測の不足と判断を変える仮定をbriefに残す。

観測した事実、確定済みの制約、未確認の仮定を分ける。実データがない場合は、空、最短、最長、欠損、大量、権限差、遅延を含む代表例を仮定として明示する。利用者やbrandの情報がないまま、架空のpersonaやvisual identityを補わない。

通常の変更では、既存design systemを既定値として継承する。今回のtaskやcontentを表現できない箇所だけをgapとして示し、既存tokenで足りる箇所へ別のscale、palette、component variantを作らない。
既存UIの評価や再設計が明示された場合は「既存UIの評価と再設計を依頼されたとき」に従い、出典のある実制約を除いて改定できる対象として扱う。

比率、幅、breakpoint、target sizeなどの数値は、既存system、実content、platform要件、測定のいずれかから導ける場合だけ確定する。根拠がなければ、保つ優先順位と判断条件を示し、もっともらしい数値を作らない。design-system gapは不足する状態、振る舞い、表現能力として渡し、新しいcomponent名やtoken名をこの段階で正本化しない。

## 仕事の順序を情報構造へ写す

主要taskを、入口、判断、操作、完了確認まで一続きで追う。各段階で利用者が答える問い、必要な情報、次の操作を特定し、その順に情報階層、wayfinding、progressive disclosureを決める。

layoutはtaskの順序、比較対象、content量、操作頻度から導く。関連する情報を近づけ、主要判断を支えない装飾やcontainerを増やさない。card、sidebar、dashboard、modalを生成上の既定形として選ばない。

## Interactionを画面の応答まで閉じる

重要な操作ごとに次を一つの流れとして設計する。

1. 何が操作可能だと伝えるか
2. どの入力で何を起こすか
3. 実行条件と結果をいつ示すか
4. 処理中、成功、空、部分成功、競合、失敗をどう見せるか
5. 誤操作をどう防ぎ、取り消し、再試行、修正へどう戻すか

状態名を列挙して終えず、利用者に見える差、可能な次の操作、focusの移動、保存済みか未保存かを示す。animationは状態変化や空間関係の理解を助ける場合だけ使い、feedbackをmotionだけに依存させない。

action名は利用者が起こす結果で表し、button、処理中、完了、errorで同じ語を保つ。
空状態と失敗は雰囲気で埋めず、何がないか、何が起きたか、次にできる操作を示す。
入力は意味、必要なformat、autofill、paste、IME、errorとの対応を決め、不要な再入力を要求しない。

## Visual directionをproductから導く

productの目的、利用場面、contentの性質、brand、既存design systemから、一貫したvisual directionを一文で定める。typographyの役割と階層、色の意味、spacingとdensity、surfaceの区別、iconやimageの必要性、motionの用途を、そのdirectionと主要taskに対応させる。

扱う対象、その属性・関係・状態と、利用者が理解・比較・判断することから表現を選ぶ。table、chart、timeline、tree、map、previewなどを、情報の意味、正確な値の参照、量、探索の目的で比べる。データのfieldを並べることも、関係をすべて図にすることも既定にしない。
対象の移動、範囲選択、並べ替え、接続などの直接操作は、結果を予測できる表現、途中のpreview、取消と回復まで含めて検討する。精密な入力、一括処理、反復作業ではformやkeyboard操作とも比べ、pointerに依存しない経路を保つ。
特有の語彙、data、作業環境からproductに合う表現を導く。font、色、余白、形状、image、motionの役割を情報理解、操作、productの性格に結び、装飾の追加も一律の削除も目的にしない。既存design systemがない場合も、完成したtoken catalogを先回りして作らない。

「洗練」「印象的」のような依頼では、代表content上の構図、視線誘導、typography、密度、一貫性を比較できる評価条件へ具体化する。恣意的な点数を作らず、観測できた差と未検証の印象・好みを分ける。

## Contentと表示条件で壊す

正常なdesktop画面だけで設計を確定しない。実際に起こり得る範囲から、長い文字列、翻訳後の増幅、0件、大量件数、欠損、遅延、partial data、権限不足、stale stateを当て、階層、操作、feedbackが保たれるか確認する。

responsive設計では幅ごとの縮小版を作らず、taskの優先度に従って保持、並べ替え、折り畳み、別画面化する情報と操作を決める。pointer、touch、keyboardで主要taskを完了できる経路を示す。

notchやsoftware keyboard、sticky領域でcontentとfocusが隠れない配置を決める。
日付、数値、currency、翻訳されたaction名は対象localeで確認し、serverとclientが異なる表示条件も仮定として残す。

アクセシビリティ要件を具体化するときは[accessibility](references/accessibility.md)を読む。準拠を宣言するのではなく、今回のinteractionについてsemantic structure、keyboard、focus、status、contrast、target、motionの設計判断を残す。

## 既存UIの評価と再設計を依頼されたとき

利用者が既存UIの評価、問題点の指摘、再設計を明示した場合だけ、この節を加える。通常の画面追加や変更は上の既定を保ち、評価や再設計へ広げない。

証拠を入力にする。判断の根拠は、呼び出し側が渡した観測（snapshot、画像、操作記録、coverageと未確認条件）、source、利用者の説明である。実画面について根拠がなければ、見ていない状態を判断せず、必要な観測を対象state、content、viewport、操作として依頼条件に書く。
実画面の探索的・網羅的な監査は、利用者の明示依頼で`browser-operation`が行う仕事であり、このSkillから始めない。未実施ならcallerへ依頼条件を返し、実画面に依存する結論を保留する。

目的から評価する。利用者と事業にとってのproductの目的を、要求、source、画面の文言、利用者の説明から特定し、出典のない目的は仮定として明示する。現状の画面構成を目的と同一視せず、目的への影響で所見の重みを決める。

四つの軸を別々に評価する。

- 情報構造: 対象の分け方、関係、導線、階層
- visual: 表現の選択、階層の見え方、density、一貫性
- interaction: 操作、feedback、予防と回復
- 体験: 目的を達成するまでの流れ、迷い、手戻り、信頼

各軸に、証拠、問題、変更案、費用を結ぶ。一つの軸の問題を別の軸の変更で解決したことにせず、見た目だけの変更や情報構造だけの変更で足りるなら、その範囲を推薦する。
各所見は、観測した事実（証拠のlocator付き）、そこから推論した設計上の仮説、要求が決まっていないため判断できない事項に分ける。

既存design systemを前提にしない。業務要件、データの意味、安全性、accessibility、明示されたbrandやplatformの要件は出典と守る範囲を示す。既存libraryや運用への依存は変更の影響であり、それだけで変更不可とはしない。維持、拡張、構造からの改定を目的との整合、consumerへの影響、移行と回復の方法で比べる。
局所修正と構造変更が異なる帰結を持つ場合は、次節の基準で比較する。維持が最良なら維持を推薦し、変えること自体を目標にしない。

返す内容は、使った証拠と範囲、未確認条件、軸別の所見、実制約と改定できる部分、推薦する方向と採らなかった案の費用、利用者へ確認すべき要求である。

## 実質的な方向だけ比較する

複数案を出す場合は、情報構造、interaction、layout、densityのいずれかが実質的に異なる案だけを比較する。theme名、色、角丸だけを変えた案を別案にしない。

正しさ、利用者のtask、既存design system（評価・再設計では出典のある制約）、accessibility、実データの制約に反する案を先に落とす。残る案は、判断の速さ、誤操作、回復、情報密度、端末間の適応、追加・改定するdesign-system所有物で比較し、一案を推薦する。点数を合算しない。

## Briefを閉じる

必要な項目だけを返す。

- 確認した事実、制約、判断を変える仮定
- 主要taskと情報階層、wayfinding
- 重要なinteraction、visible state、feedback、予防と回復
- 推薦するvisual direction、layout、density、motion
- contentのstress case、responsive adaptation、accessibility要件
- 既存design systemで足りる箇所と、根拠のあるgap
- 採らなかった案と具体的な費用

production code、CSS、component tree、state owner、propsを作らない。
component構造、ownership、公開interfaceの設計が依頼に含まれる場合だけ、利用可能な`codebase-design`へbrief、制約、既存design systemと改定する範囲を渡し、構造上の判断と実装へ渡す契約を受け取る。
確定済みbriefの実装は、briefと採用したdesign systemの扱い（維持、拡張、改定）を制約とする通常の実装作業へ渡す。
実画面のaccessibility監査は`a11y-debugging`へ対象surface、入力方法、設計要件と観測証拠、機能障害の原因診断は`diagnosing-bugs`へ期待と実際、再現経路と関連sourceを渡す。
browser性能は`browser-performance`へURL、経路と測定条件、securityは`security-review`へ対象scope、境界と根拠を渡す。
これらは別専門作業が依頼され、Skillが利用可能な場合だけ行い、検証された所見と不足証拠を受け取ってcallerへ返す。
利用不能な枝を実施済みとせず、briefや設計評価を実画面の監査結果、accessibility適合、性能の実測として報告しない。
