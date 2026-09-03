---
name: ui-design
description: Produces a pre-implementation UI brief from product tasks, real content, constraints, and an existing design system. Use when deciding information hierarchy, wayfinding, interaction and affordances, user-visible states, feedback and recovery, visual direction, layout, responsive adaptation, and accessibility before frontend implementation. Inherits existing design systems and extends only demonstrated gaps. Does not design private component trees, state ownership, props, module ownership, or public component contracts; write frontend code; audit a rendered UI; or diagnose browser bugs, performance, or security.
---

# 利用者の仕事からUI briefを作る

成果は画面部品の一覧ではない。利用者が目的を達成する順序と、各操作に対する画面の応答を、実装前に判断できるUI briefである。

## 現在の文脈を確認する

productの目的、利用者、利用場面、主要task、実データと値の範囲、表示文言、端末、入力方法、技術上と運用上の制約を確認する。repositoryがある場合は、既存画面、design system、token、shared primitive、content規約、accessibility要件を先に読む。
実装済みsurfaceの状態や実contentをbrowserで確認する場合は`browser-operation`へ観測taskを渡し、その証拠を設計入力として使う。repository内のdesign system、token、shared primitiveの所在や関係が不明なら`repository-research`を使う。

観測した事実、確定済みの制約、未確認の仮定を分ける。実データがない場合は、空、最短、最長、欠損、大量、権限差、遅延を含む代表例を仮定として明示する。利用者やbrandの情報がないまま、架空のpersonaやvisual identityを補わない。

既存design systemは既定値として継承する。今回のtaskやcontentを表現できない箇所だけをgapとして示し、既存tokenで足りる箇所へ別のscale、palette、component variantを作らない。

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

## Visual directionをproductから導く

productの目的、利用場面、contentの性質、brand、既存design systemから、一貫したvisual directionを一文で定める。typographyの役割と階層、色の意味、spacingとdensity、surfaceの区別、iconやimageの必要性、motionの用途を、そのdirectionと主要taskに対応させる。

特有の語彙、data、作業環境から必要な個性を作る。意味のないgradient、過剰なcard、decorative metric、generic dashboard layoutで差別化を代用しない。既存design systemがない場合も、今回必要な役割だけを定め、完成したtoken catalogを先回りして作らない。

## Contentと表示条件で壊す

正常なdesktop画面だけで設計を確定しない。実際に起こり得る範囲から、長い文字列、翻訳後の増幅、0件、大量件数、欠損、遅延、partial data、権限不足、stale stateを当て、階層、操作、feedbackが保たれるか確認する。

responsive設計では幅ごとの縮小版を作らず、taskの優先度に従って保持、並べ替え、折り畳み、別画面化する情報と操作を決める。pointer、touch、keyboardで主要taskを完了できる経路を示す。

アクセシビリティ要件を具体化するときは[accessibility](references/accessibility.md)を読む。準拠を宣言するのではなく、今回のinteractionについてsemantic structure、keyboard、focus、status、contrast、target、motionの設計判断を残す。

## 実質的な方向だけ比較する

複数案を出す場合は、情報構造、interaction、layout、densityのいずれかが実質的に異なる案だけを比較する。theme名、色、角丸だけを変えた案を別案にしない。

正しさ、利用者のtask、既存design system、accessibility、実データの制約に反する案を先に落とす。残る案は、判断の速さ、誤操作、回復、情報密度、端末間の適応、追加するdesign-system所有物で比較し、一案を推薦する。点数を合算しない。

## Briefを閉じる

必要な項目だけを返す。

- 確認した事実、制約、判断を変える仮定
- 主要taskと情報階層、wayfinding
- 重要なinteraction、visible state、feedback、予防と回復
- 推薦するvisual direction、layout、density、motion
- contentのstress case、responsive adaptation、accessibility要件
- 既存design systemで足りる箇所と、根拠のあるgap
- 採らなかった案と具体的な費用

production code、CSS、component tree、state owner、propsを作らない。内部component構造は`code-design`、shared ownerは`module-design`、公開component contractは`interface-design`へ渡す。確定済みbriefの実装に独立Skillは使わず、briefと既存design systemを制約とする通常の実装作業へ渡す。実画面の監査は対象外とし、機能障害は`bug-analysis`、性能は`performance-analysis`、securityは`security-scan`が所有する。
