---
name: web-researcher
description: 外部 Web の事実を、searxng で URL を列挙し、crawl4ai で本文を取って、複数源比較で引用付き回答する手順。snippet 推測 / 単一源の断定 / library docs を web で始める / 古い記事を新しいと誤認、の 4 失敗を構造的に塞ぐ。Claude / Codex が独力で WebSearch を投げると起きがちな失敗を MCP target の責務固定で防ぐ。
---

# Web Researcher

Web を調べるとき、agent は snippet で答えを推測したり、1 件だけ読んで断定したり、ライブラリ公式 docs を取りこぼしたまま二次資料を信じたりしがち。本 skill は次の 3 つを分業に固定する。

- 検索 = URL を列挙するだけ(`searxng.searxng_web_search`)
- 本文取得 = URL から markdown を作る(`crawl4ai`)
- 判断 = 複数源を比較して引用付きで答える(agent 自身)

責務を分けることで「snippet で済ませる」「1 件で断定する」が構造的に発生しにくくなる。

## いつ使うか

- 外部 Web の事実が必要で、`context7` と `probe` だけでは足りないとき
- 一次資料を引用付きで提示する必要があるとき
- 時系列で動く話題(リリース、価格、議論の経緯、最近の API 変更)を扱うとき

使わない場面:
- ライブラリ / フレームワークの公式 docs を引きたい → `context7` を先に試す
- 自リポ内のコードを理解したい → `probe` を先に試す
- 計算や推論で答えが出る、検索する必要のない話題
- 自分のメンタル知識で十分自明な事実(検索する前に答えられる)

## ワークフロー

### 1. クエリ設計

`searxng.searxng_web_search` を呼ぶ前に、漠然と `<query>` を投げるのをやめる。次の 4 つを組み立ててから検索する。

- **bang で source を絞る**: `!so`(Stack Overflow)/ `!gh`(GitHub)/ `!arxiv` / `!scholar` / `!wp`(Wikipedia)。複数併用可。コード例なら `!so !gh`、論文なら `!arxiv !scholar`。
- **site filter**: 出元が決まっているなら `site:docs.<project>.org <query>` のように絞る。
- **time_range**: 時系列を効かせたいときに `time_range=day` / `week` / `month` / `year`。リリース / 議論 / 価格などの動く話題で必須。
- **言語**: 日本語固有の議論なら `:ja`、英語 primary なら `:en`。

`searxng.web_url_read` は呼ばない。本文取得は `crawl4ai` の責務。

### 2. URL 選別

上位 5-10 件の URL リストから、本文取得に進める候補を 2-3 件に絞る。

優先する source:
- 公式 docs、GitHub release、論文 PDF、著者本人の blog
- 主要 tech blog、Stack Overflow accepted answer、Wikipedia

避ける source:
- SEO スパム、AI 生成記事、`<query> とは` 形式の量産サイト
- snippet の文面が他の検索結果と酷似している(コピー記事の疑い)

URL から完全には見分けられない。次の step で本文を取って判断材料を増やす。snippet で結論を出さない。

### 3. 本文取得

`crawl4ai` target の MCP tool を呼ぶ。gateway が spawn する stdio front(`crawl4ai-mcp`)が crawl4ai engine の REST を中継し、次を提供する。

| tool | 入力 | 出力 |
|---|---|---|
| `crawl4ai.md` | 単一 URL | markdown(内部 filter 適用済) |
| `crawl4ai.html` | 単一 URL | preprocessed HTML |
| `crawl4ai.crawl` | URL list | 各 URL の markdown |
| `crawl4ai.execute_js` | URL + JS code | JS 実行後の DOM |
| `crawl4ai.screenshot` | URL | image |
| `crawl4ai.pdf` | URL | PDF |
| `crawl4ai.ask` | query | Crawl4AI library 内 context |

第一選択は `crawl4ai.md` の単発、複数なら `crawl4ai.crawl(urls=[...])` でまとめて取る。

ケース別の切替:

| 状況 | tool |
|---|---|
| SPA / 動的 JS で `crawl4ai.md` が空を返す | `crawl4ai.execute_js` で wait_for と scroll を仕込む |
| 論文 / 仕様書の PDF | `crawl4ai.pdf` |
| 図表 / レイアウトの確認 | `crawl4ai.screenshot` |
| 複数 URL の一括取得 | `crawl4ai.crawl` |

`PruningContentFilter` / `BM25ContentFilter` / `fit_markdown` / `BFSDeepCrawlStrategy` / `KeywordRelevanceScorer` / `crawl_sitemap` などは Python SDK 専用で、MCP からは呼べない。深く掘るときは別途 Python SDK を直接使う(本 skill の scope 外)。

### 4. 比較

取得した本文を 4 軸で評価する。

| 軸 | 取り方 |
|---|---|
| 鮮度 | URL の日付、本文中の年月日、最終更新の signal |
| 一次性 | 公式か、著者本人か、二次資料か |
| 一致度 | 複数源で同じ事実か、矛盾しているか |
| 引用の質 | source が自分の出典を明示しているか(さらに上の一次資料に辿れるか) |

一致しないときは追加で 1-2 件取って三角測量する。

### 5. 回答

回答に引用元 URL を必ず明示する。形式は次のいずれか。

- 事実ごとに `[^N]` 脚注、末尾に `## Sources` 節
- インライン `[タイトル](URL)` リンク

情報源が単一の場合は **その限界を明示する**(「現時点で一次資料 1 件のみ、追加検証推奨」)。矛盾する説があれば併記し、どちらが正しいかを断定しない(根拠の差を示すだけ)。

## 環境制約と回避

| 制約 | 回避 |
|---|---|
| Cloudflare bot 保護で 403 | 別 source を当たる。MCP からは stealth 機能が制限される |
| login wall | API 経路に切替(GitHub なら `github-<account>`) |
| 古い記事が SEO で上位 | URL の日付 + 本文中の年月日を必ず照合、`time_range` で絞る |
| 検索 engine の偏り | bang で複数 engine を散らす |
| 日本語固有の話題で英語結果しか出ない | `:ja` を付ける、`site:zenn.dev` / `site:qiita.com` を試す |
| SPA で本文 0 文字 | `crawl4ai.md` ではなく `crawl4ai.execute_js` |

## 打ち切り基準

- **収束**: 2-3 件の一次資料で事実が一致、矛盾なし → 引用付きで回答する
- **矛盾あり**: 追加 1-2 件取得して三角測量、それでも決まらなければ両説併記
- **資料不足**: 1 件しか見つからない、または全て二次資料 → 「現時点で N 源、追加検証必要」と明示
- **資源打ち切り**: 8-10 件読んで決着しなければ、その時点の暫定回答 + 残課題を提示

## 提示フォーマット

```text
<回答本文、事実ごとに [^N] 引用>

## Sources
- [^1]: <タイトル> <URL>(取得 YYYY-MM-DD)
- [^2]: <タイトル> <URL>(取得 YYYY-MM-DD)

## 確認できなかった点
- <事実 X はどの source でも明示されていなかった>
- <一次資料が見つからず二次資料 N 件で構成>
```

## Red flags

| 出てくる合理化 | 実態 |
|---|---|
| snippet で答えが書いてある、本文要らない | snippet は HTML 先頭の機械抽出。誤誘導が多い。本文を取る |
| 1 件で十分 | 1 件は反証されない、矛盾も検知できない。最低 2 件 |
| 公式 docs を web で検索すれば速い | `context7` を先に試す。`context7` で取れる範囲を web に投げると劣化 |
| 自リポのコードも web で見つかる | `probe` を先に。web の検索結果は時系列で古い可能性 |
| `searxng.web_url_read` で本文取れる | `node-html-markdown` の機械変換のみでノイズ除去なし。`crawl4ai.md` を使う |
| snippet と順位だけで信頼性を判断できる | SEO スパムも順位を取る。本文を読む |
| 最新の話題だから上位 = 新しい | 古い記事も SEO で上位に残る。日付を確認 |
| 英語で検索すれば日本語固有の話題も拾える | 日本語の議論は日本語 source にしかない。`:ja` を付ける |

## よくある失敗

- クエリが漠然。`<query>` だけで bang / site / time_range / 言語のどれも付けない。一次資料が埋もれる
- 取った 2 件が同じ source の copy。source の多様性を確保していない
- 本文を読まずに snippet で結論。`crawl4ai` を呼んだ意味がない
- URL 日付と本文日付を見ていない。古い記事を新しいと誤認する典型
- PDF / SPA に普通の `crawl4ai.md` を投げて空が返ったので諦める。tool 切替で取れる
- 引用なしで断定。後から検証不能、`Sources` 節を必ず付ける
- `crawl4ai` の SDK 機能を MCP から呼ぼうとする。MCP 経由では使えない、Python SDK を別途立てる

## 関連

- `context7` MCP target:library / framework の公式 docs。本 skill より先に試す
- `probe` MCP target:自リポのコード検索。本 skill より先に試す
- `WebSearch` 内蔵 tool:Claude / Codex の内蔵検索。`searxng` が落ちているときの fallback。snippet ベースで本 skill の用途には届かない
