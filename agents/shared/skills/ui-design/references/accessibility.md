# UI設計で確認するアクセシビリティ

productや法令が準拠水準を定めている場合は、その要件を優先する。要件がない場合も、関連するWCAG 2.2の達成基準を設計上のrisk baselineとして使う。実装と試験をしていない画面を準拠済みと書かない。

## 構造と名前

- 見出し、領域、list、table、formの関係を見た目だけで表さない。
- native controlで表せる操作は、そのroleとkeyboard behaviorを基準にする。
- controlのaccessible name、説明、error、対象との対応を決める。iconや位置だけを名前にしない。
- 読み順と操作順をtaskの順序に合わせる。visual orderだけをCSSで入れ替えない。

## Keyboardとfocus

- pointerなしで主要taskを完了できる経路を示す。
- focus indicatorが背景や状態に埋もれず、sticky elementやoverlayで隠れない配置にする。
- dialog、popover、menu、非同期更新の前後で、focusをどこへ移し、どこへ戻すか決める。
- drag、swipe、hoverだけに依存する操作には、同じ結果へ到達する単純な入力経路を用意する。

## 状態とfeedback

- validation errorは対象、原因、修正方法を結び付ける。色だけで示さない。
- loading、保存、成功、失敗、更新件数の変化を、適切なstatusとして支援技術へ伝える設計にする。
- timeoutやsession lossがあるflowでは、残り時間、延長、再開、入力保持の扱いを決める。
- 認証や再入力で、不要な記憶、転記、同じ情報の反復入力を要求しない。

## 視認性と操作領域

- 通常textは4.5:1、大きなtextは3:1、操作部品と意味を持つgraphicは隣接色に対して3:1を基準に確認する。例外は該当する達成基準で判断する。
- 状態や選択を色だけで伝えず、文言、形、icon、programmatic stateのうち文脈に合う手掛かりを併用する。
- targetは少なくとも24×24 CSS px相当か、隣接targetとの間隔を含むWCAG 2.2の例外条件を満たす設計にする。productがより大きい基準を持つ場合はそちらを使う。
- zoom、text拡大、長い翻訳でcontrolやcontentが欠落しない再配置を決める。

## Motionと時間

- motionを情報理解に使う場合も、prefers-reduced-motionに対応する代替を決める。
- 点滅、parallax、autoplay、時間制限はtaskに必要な場合だけ使い、停止、延長、非motionのfeedbackを用意する。

根拠は[WCAG 2.2](https://www.w3.org/TR/WCAG22/)と[WAI-ARIA Authoring Practices Guide](https://www.w3.org/WAI/ARIA/apg/)で確認する。pattern例をそのまま採用せず、native semanticsとprojectの実装規約を先に使う。
