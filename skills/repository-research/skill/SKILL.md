---
name: repository-research
description: Researches local repository concepts, relationships, and multi-file behavior when their wording or location is unknown. Routes semantic discovery through the configured Zvec-Grep MCP and falls back to native repository tools when no current index is available, then verifies every material claim in source. Routes exact text, paths, and symbols directly to native tools. Does not manage indexes, analyze dependency graphs or a concrete change's blast radius, or research the external Web.
---

# Repositoryを調査する

成果は検索hitの一覧ではなく、問いに答えるsource-backedな説明と、そこへ至る確認可能な証拠経路である。候補発見、source検証、関係の統合を所有し、Zvec-Grepを呼ぶだけのSkillにはしない。

## Jobを固定する

調べるrepository、revision、subsystemと問いを先に固定する。問いを、見つけるべき概念、主体、関係、制約、状態遷移へ分ける。用語や所在が既知か、複数fileをまたぐ意味の統合が必要かを区別してから探索経路を選ぶ。

実装名を推測して問いを置き換えない。利用者の表現と確認したexact anchorを保持し、推測した名称は候補としてだけ扱う。

## 探索経路を選ぶ

最小で決定的な経路を優先する。

- 既知のfileや範囲を読むなら`Read`
- exactなfile名、directory、path patternを探すなら`Glob`
- exact text、error、設定key、literal、regex、網羅的な出現箇所なら`Grep`または`rg`
- 既知symbolの定義、参照、型、call hierarchyならLSP
- 表現や所在が不明な概念、複数component間の関係、複数fileからのbehaviorやrationaleの統合ならZvec-Grep

semantic探索とexact anchorの両方が必要なら、概念と関係を保った問いで候補を得てから、`Read`、`Grep`、`Glob`、LSP、`rg`で定義と経路を絞る。既知symbol一件の参照列挙や、literalの完全一致をZvec-Grepへ迂回させない。

## Zvec-Grepを使う条件

semanticまたはmixedなrepository調査では、`repository-search` Capabilityが公開する`zvec_grep_search`を先に使う。
このsessionの入口は`xd://mcp__gateway_zvec_grep_zvec_grep_search`であり、schemaを読んでから`root`へdaemonに見えるworkspaceの絶対path、`query`へ問い、`autoUpdate: false`をJSONで渡す。
複数の問いは`queries`、確認済みexact anchorは補助の`fts`、補助の意味検索は`vector`へ分けられ、一つの順位へ統合する場合だけ`fuse: true`を使う。
これらは検索経路であり、hard filterとは扱わない。
応答のroot、scope、freshness、`background_refresh`を読み、current indexから返った十分なsnippetは直ちに使い、更新中という理由だけでstatus確認や再検索を足さない。
公開入口が利用不能、またはindexがない場合はnativeなrepository toolへ戻り、その探索経路を結果に記す。

queryには調査対象の概念、期待する関係、制約をそのまま含める。
確認済みのsymbolや用語はanchorとして追加できるが、それだけでsemantic intentを狭めない。
persistent indexの作成、refresh、再構築、削除、設定変更を行わず、探索のためにindex管理を利用者へ求めない。

結果が無関係または偏っている場合は、落ちた概念や関係を補って問いを組み直す。それでも有力候補が得られなければ、似たqueryを反復せず、exact探索か既知の入口からのsource追跡へ切り替える。

## Sourceで検証する

検索scoreと語の近接は証拠ではない。
current indexのsource locator付きsnippetが主張を支える範囲を全て含む場合は、既読sourceとして扱う。
materialなclaimごとに次を行う。

1. snippetの外に必要な定義、control、周辺条件がある場合だけ、候補が指すsource fileの該当範囲を直接読む。
2. 定義、caller、reader、writer、設定、schema、testなど、その関係を成立させる両端を確認する。
3. 静的な参照とruntime behavior、規範的な契約と例示、production codeとtestやgenerated codeを区別する。
4. fileと範囲に紐づけて、sourceが直接示す事実、そこからの解釈、未確認事項を分ける。

名前の類似、snippet内の共起、検索順位だけから関係を断定しない。
必要なsourceがsnippetにも直接の読取りにもなければ、候補を証拠へ昇格させない。
sourceが変わっていれば直接読んだ現在のsourceを優先し、index由来の古い推測を捨てる。

## 停止条件

問いの各部分に直接sourceの根拠があり、追加候補が結論や未確定事項を変えなくなったら停止する。網羅性が必要なexact searchは、対象scopeを明示してnative toolで完了させる。

既存indexがないことを探索失敗として扱わない。native toolで到達できる範囲を調べ、dynamic behavior、生成物、外部consumerなどsourceだけで確定できないものは不明とする。検証できない関係を埋めるために探索範囲を無制限に広げない。

## 結果を返す

必要な項目だけを返す。

- 固定した問い、scope、revision
- 確認した概念、定義、関係、behavior
- 各material claimを支えるsource fileと範囲
- 観測事実、解釈、残る不確実性
- 除外した範囲と、結論を変え得る不足証拠

候補snippetやhit数を最終成果にせず、なぜそのsourceから結論が導けるかを示す。

## Handoffとnon-goals

依存graph、cycle、fan-in、fan-out、transitive reachabilityの分析が必要な場合は、利用可能な`dependency-analysis`へ問い、scope、検証済みのnodeとedgeの候補、source locatorを渡し、graphの定義と根拠付きの分析を受け取る。
具体的な変更のblast radiusが必要なら`impact-analysis`へ変更契約、revision、確認したconsumerと境界、未確定事項を渡し、互換性、rollout、rollbackへの影響を受け取る。
公開URL、最新情報、外部仕様が必要なら`web-research`へ外部の問い、versionと時点、確認済みURLを渡し、一次source付きの結果を受け取る。
専門結果を元の問いへ結び付けて返し、利用不能な枝は不足する専門作業と証拠を明示する。

このSkillはpersistent indexを管理せず、既知のexact text、path、symbol探索を包まない。
architectureの良否判定、設計、bugの原因診断、変更の実装も所有しない。
別Skillへ渡す場合は、ここで検証済みのsourceと未確定事項だけを証拠として引き継ぐ。
