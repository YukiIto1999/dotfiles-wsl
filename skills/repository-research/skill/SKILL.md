---
name: repository-research
description: Traces how local code works and maps source, runtime, build, or deployment dependencies. Use for unknown repository behavior, cross-file evidence, cycles, and transitive paths. Known text, paths, and symbols go directly to native tools. Does not assess the blast radius of a proposed change, design new boundaries, or research the Web.
---

# Repositoryを調査する

成果は検索hitの一覧ではなく、問いに答えるsource-backedな説明と、そこへ至る確認可能な証拠経路である。候補発見、source検証、関係の統合を所有する。

## Jobを固定する

調べるrepository、revision、subsystemと問いを先に固定する。問いを、見つけるべき概念、主体、関係、制約、状態遷移へ分ける。用語や所在が既知か、複数fileをまたぐ意味の統合が必要かを区別してから探索経路を選ぶ。

実装名を推測して問いを置き換えない。利用者の表現と確認したexact anchorを保持し、推測した名称は候補としてだけ扱う。

## 探索経路を選ぶ

最小で決定的な経路を優先する。

- 既知のfileや範囲を読むなら`Read`
- exactなfile名、directory、path patternを探すなら`Glob`
- exact text、error、設定key、literal、regex、網羅的な出現箇所なら`Grep`または`rg`
- 既知symbolの定義、参照、型、call hierarchyならLSP
- ASTの構造patternは`ast-grep`、変更や所有の履歴は対象pathに絞ったGit。文字列をsemanticな参照の代わりにしない。
- 表現や所在が不明な箇所を絞るなら、clientが公開する意味探索（OMPでは`find`）を使う。専用入口がなければ、既知の入口・関連語から`Read`と`Grep`で追う。

semantic探索とexact anchorの両方が必要なら、概念と関係を保った問いで候補を得てから、`Read`、`Grep`、`Glob`、LSP、`rg`で定義と経路を絞る。

## 意味探索の問いを組む

queryには調査対象の概念、期待する関係、制約をそのまま含める。
確認済みのsymbolや用語はanchorとして追加できるが、それだけでsemantic intentを狭めない。
すでに十分な根拠があれば同じ問いを投げ直さない。

結果が無関係または偏っている場合は、落ちた概念や関係を補って問いを組み直す。それでも有力候補が得られなければ、似たqueryを反復せず、exact探索か既知の入口からのsource追跡へ切り替える。

## Sourceで検証する

検索scoreと語の近接は証拠ではない。
探索結果のsource locator付きsnippetが現在のsourceから取られ、主張を支える範囲を全て含む場合は、既読sourceとして扱う。
materialなclaimごとに次を行う。

1. snippetの外に必要な定義、control、周辺条件がある場合だけ、候補が指すsource fileの該当範囲を直接読む。
2. 定義、caller、reader、writer、設定、schema、testなど、その関係を成立させる両端を確認する。
3. 静的な参照とruntime behavior、規範的な契約と例示、production codeとtestやgenerated codeを区別する。
4. fileと範囲に紐づけて、sourceが直接示す事実、そこからの解釈、未確認事項を分ける。

名前の類似、snippet内の共起、検索順位だけから関係を断定しない。
必要なsourceがsnippetにも直接の読取りにもなければ、候補を証拠へ昇格させない。

## 依存構造を確かめる

抽出前にnodeの粒度、edgeの意味と方向、対象revisionと実行条件、test・生成物を含めるかを決める。例として`A -> B`は「AがBを必要とする」を表す。参照、呼出し、データの生成と消費、build順序、同時deploy、共変更は別の関係として扱う。

言語resolver、compiler、manifest、schema、service定義、LSP、AST、実行traceを問いに合わせて使う。既知の依存と非依存をsourceに照合してから集計し、直接edgeと推移経路を分ける。cycleは同じedge種別・粒度で互いに到達できる集合を指す。具体的な初期化、build、test、deployの制約を示せないなら、cycleやfan-in/outの値だけで欠陥と判定しない。

条件付きimport、re-export、生成物、feature flag、反射、共有状態・暗黙の順序は調べた条件を添える。Gitの共変更は所有や変更理由の候補であり、実行時依存の証明ではない。実行時の証拠はprojectが宣言するcommandまたは公開Capabilityから採り、未観測のedgeは不明とする。

## 停止条件

問いの各部分に直接sourceの根拠があり、追加候補が結論や未確定事項を変えなくなったら停止する。網羅性が必要なexact searchは、対象scopeを明示してnative toolで完了させる。

native toolで到達できる範囲を調べ、dynamic behavior、生成物、外部consumerなどsourceだけで確定できないものは不明とする。検証できない関係を埋めるために探索範囲を無制限に広げない。

## 結果を返す

必要な項目だけを返す。

- 固定した問い、scope、revision
- 確認した概念、定義、関係、behavior
- 各material claimを支えるsource fileと範囲
- 観測事実、解釈、残る不確実性
- 除外した範囲と、結論を変え得る不足証拠

候補snippetやhit数を最終成果にせず、なぜそのsourceから結論が導けるかを示す。

## Handoffとnon-goals

具体的な変更のblast radiusが必要なら`impact-analysis`へ変更契約、revision、確認したconsumerと境界、未確定事項を渡し、互換性、rollout、rollbackへの影響を受け取る。
公開URL、最新情報、外部仕様が必要なら`web-research`へ外部の問い、versionと時点、確認済みURLを渡し、一次source付きの結果を受け取る。
専門結果を元の問いへ結び付けて返し、利用不能な枝は不足する専門作業と証拠を明示する。

このSkillは既知のexact text、path、symbol探索を包まない。
architectureの良否判定、設計、bugの原因診断、変更の実装も所有しない。
別Skillへ渡す場合は、ここで検証済みのsourceと未確定事項だけを証拠として引き継ぐ。
