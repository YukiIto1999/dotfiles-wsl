# HTML reportの形式

architecture reviewは、OSのtemp directoryに置く自己完結した単一のHTML fileとして出す。TailwindとMermaidはどちらもCDNから読む。Mermaidはgraph型の図に向き、手組みのdivとinline SVGは編集的な図(mass diagram、cross-section)に向く。二つを混ぜ、Mermaidだけに頼らない。単調な見た目になる。

## 雛形

```html
<!doctype html>
<html lang="{{利用者の言語}}">
  <head>
    <meta charset="utf-8" />
    <title>Architecture review for {{repo name}}</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script type="module">
      import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
      mermaid.initialize({ startOnLoad: true, theme: "neutral", securityLevel: "loose" });
    </script>
    <style>
      /* Tailwindだけでは書きにくい小さな層:
         破線のseam、手描き風の矢じりなど */
      .seam { stroke-dasharray: 4 4; }
      .leak { stroke: #dc2626; }
      .deep { background: linear-gradient(135deg, #0f172a, #1e293b); }
    </style>
  </head>
  <body class="bg-stone-50 text-slate-900 font-sans">
    <main class="max-w-5xl mx-auto px-6 py-12 space-y-12">
      <header>...</header>
      <section id="candidates" class="space-y-10">...</section>
      <section id="top-recommendation">...</section>
    </main>
  </body>
</html>
```

## Header

repository名、日付、簡潔な凡例を置く。凡例は、実線の箱 = module、破線 = seam、赤い矢印 = 漏れ、太く濃い箱 = deep moduleである。導入の段落は置かず、すぐ候補へ入る。

## Candidate card

図が主役である。文は少なく平易にし、用語は`codebase-design`の語彙を飾らず使う。

各候補は一つの`<article>`にする。

- **Title**: 短く、deepeningを名指す(例: 「Order intake pipelineを一つにまとめる」)。
- **Badge row**: 推薦の強さ(`Strong` = emerald、`Worth exploring` = amber、`Speculative` = slate)と、`codebase-design`の分類名による依存の性質のtag。
- **Files**: 等幅の一覧(`font-mono text-sm`)。
- **Before / After diagram**: 中心になる図。二列を並べる。型は下の節を参照する。
- **Problem**: 一文。何が困るか。
- **Solution**: 一文。何が変わるか。統合を含む候補は、統合する対象が同じ決定、権限、状態の寿命を共有する根拠と、既存testの扱いも示す。
- **Wins**: 箇条書き。各項目は短い語句にする(例: 「testがinterface一つに届く」「Pricingの論理が漏れなくなる」「shallowなmoduleを4つ削除」)。
- **ADR callout**(該当する場合): 琥珀色の箱に一行。

説明の段落は置かない。図の理解に段落が要るなら、図を描き直す。

## Diagram patterns

候補に合う型を選び、混ぜる。すべての図を同じ見た目にしない。変化もこの図の狙いである。

### Mermaid graph(依存や呼出しの流れの主力)

「XがYを呼び、YがZを呼び、この混乱を見よ」という点には、Mermaidの`flowchart`か`graph`を使う。Tailwindで整えたcardで包み、外から貼り付けた印象にしない。classDefで漏れる辺を赤、deep moduleを濃色にする。sequence図は、「before: 往復6回、after: 1回」を示すのに向く。

```html
<div class="rounded-lg border border-slate-200 bg-white p-4">
  <pre class="mermaid">
    flowchart LR
      A[OrderHandler] --> B[OrderValidator]
      B --> C[OrderRepo]
      C -.leak.-> D[PricingClient]
      classDef leak stroke:#dc2626,stroke-width:2px;
      class C,D leak
  </pre>
</div>
```

### 手組みの箱と矢印(Mermaidのlayoutが合わないとき)

moduleは、枠とラベルを付けた`<div>`で描く。矢印は、相対位置のcontainer上に絶対位置で置いたinline SVGの`<line>`か`<path>`で描く。「after」の図を、内部を薄くした太枠の一つのdeep moduleとして見せたいときに使う。Mermaidでは適切な重さで描けない。

### Cross-section(層状のshallowさに向く)

水平の帯(`h-12 border-l-4`)を積み、呼出しが通る層を示す。before: 何もしない薄い層が6枚。after: 統合した責務の名を付けた太い帯が1枚。

### Mass diagram(「interfaceが実装と同じ幅」に向く)

moduleごとに二つの長方形を描く。interfaceの表面積と実装である。before: interfaceの長方形が実装とほぼ同じ高さ(shallow)。after: interfaceは短く、実装は高い(deep)。この図は構造の説明であり、depthの測定値ではない。実装とinterfaceの行数の比を数字で示さない。

### Call-graph collapse

before: 関数呼出しの木を入れ子の箱で描く。after: 同じ木を一つの箱へ畳み、内部になった呼出しを薄く内側に残す。

## Style guidance

- 企業のdashboardでなく、編集的な見た目にする。余白を広くとる。見出しにserifを使ってもよい(stoneとslateに`font-serif`が合う)。
- 色は控えめにする。accentはemeraldかindigoの一色、漏れは赤、警告は琥珀色にする。
- 図の高さは約320pxにして、before/afterがscrollなしで並ぶようにする。
- 図の中のmoduleのラベルには`text-xs uppercase tracking-wider`を使い、UIでなく模式図として読ませる。
- scriptはTailwindのCDNとMermaidのESM importだけにする。reportはそれ以外は静的で、application codeも、Mermaid自身の描画を除く対話もない。

## Top recommendation section

大きめのcardを一つ置く。候補名、理由を一文、そのcardへのanchor linkだけを載せる。

## Tone

簡潔に書き、architectureの名詞と動詞は`codebase-design`の語彙から取る。簡潔さを、語彙から外れてよい理由にしない。

moduleのつもりでcomponent、service、unit、layer、wrapperと書かない。interfaceのつもりでAPIやsignature、seamのつもりでboundaryと書かない。

文の型の例:

- 「Order intake moduleはshallow: interfaceが実装とほぼ同じ複雑さ。」
- 「Pricingがseamを越えて漏れている。」
- 「Deepen: interfaceは一つ、testする場所も一つ。」
- 「正本とcacheは権限と寿命が違うため、seamは内側に残る。」

**Winsの項目**は、得るものを語彙で示す。例は「locality: 不具合が一つのmoduleに集まる」「leverage: interface一つ、呼出しN箇所」「interfaceが縮み、implementationが薄いmoduleを吸収する」である。「保守しやすい」「コードがきれい」とは書かない。語彙にない語で、得るものが具体にならない。

ためらいや前置きを書かない。一文が箇条書きにできるなら箇条書きにし、削れる項目は削る。語彙にない語を使いたくなったら、新しく作る前に`codebase-design`の語彙から選ぶ。
