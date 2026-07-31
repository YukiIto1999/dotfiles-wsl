# 0018. 責務が異なる限り、領域の重なるツールを併存させる

## 状態

Accepted

## 背景

同じ領域に複数のツールがあると、重複に見えて削減の候補になる。2026 年 7 月の構成監査で、devenv と Nix、SearXNG と Crawl4AI、Context7 と Probe、curl と xh、jq と yq の global package と command closure、複数の GitHub account が候補に挙がった。

判断の根拠を残さないと、次に構成を見た者が同じ検討を繰り返すか、責務の違いに気付かずに片方を削る。この判断は参照文書の表として置かれていたが、参照は調べたい読み手のための種別であり、なぜそう決めたかを持つ場所ではない。

## 決定

領域が重なるツールは、責務が異なる限り併存させる。削減の判断は、責務の重複を示してから行う。利用回数の多寡だけを根拠にしない。

| 構成 | 併存させる理由 |
|---|---|
| devenv、direnv、nix-direnv | project-local な開発環境を構築し、checkout ごとの package と環境変数を有効化する。system の宣言とは対象が違う |
| SearXNG、Crawl4AI | SearXNG が URL を列挙し、Crawl4AI が本文を取得する。探索と取得で責務が分かれる |
| Context7、Probe | Context7 が library の一次資料を引き、Probe がローカル repository の構造を探索する。対象が外部と内部で分かれる |
| agentmemory | 長期記憶と lifecycle hook の基盤であり、他に代替を持たない |
| 複数 GitHub account | account ごとの credential と repository 権限を分離する |
| curl、xh | curl を script の安定した HTTP client、xh を対話操作に使う |
| jq、yq | 対話利用の global package と、再現可能な運用 command の runtime closure で、固定する版の要件が違う |

短い観測期間の call 数は、削減の根拠にしない。監査時点で codex と三番目の GitHub account の call は 0 だったが、10 時間の観測でしかなく、利用の有無を決められない。

## 検討した代替案

利用実績の少ないものから削る案。allowlist の件数と call 数は利用許可と一時点の観測であり、必要性の証明にならない。project-local 環境が同名 package を供給する場合、global の利用実績は global の必要性を示さない。責務の重複を示さずに削ると、後で戻す作業が生じるため不採用。

判断を参照文書に置き続ける案。`principles` の文書規律では、参照は調べたい読み手のための種別であり、決定の記録とは読み手が異なる。混ぜると両方が役に立たなくなるため不採用。

## 影響

`docs/reference/tooling.md` から「役割」表を外し、この ADR を指す。参照文書は正本の場所と現在値の取り方だけを持つ。

削減を提案するときは、責務の重複をこの表に照らして示す。示せない提案は採らない。
