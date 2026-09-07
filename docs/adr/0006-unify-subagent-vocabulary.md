# ADR 0006: 委譲先の定義を subagent の語に統一する

**読み手:** role、definition、agent のどれが同じ概念を指すのかを判断する人。

## Status

Accepted

## Context

委譲先の定義という一つの概念が、三つの語で表れている。ディレクトリと `routing.nix` は role と `agent`、`agents/module.nix` と client contract は definition（`shared.definitions`、`definitionsDestination`、`definitionFormat`、`definitionMode`）、配布する policy 本文と `docs/` は subagent である。

同時に `agent` の語が二つの概念に流用されている。`dotfiles.agents.clients` は AI CLI を指し、`routing.nix` の `agent` は委譲先の定義を指す。

標準は、一つのコンテキストの同じ媒体で同義の語や旧名称を混在させること、および一つの語を異なる概念へ流用することを禁じ、同一の概念がコード、schema、test、文書から同じ概念として追跡できることを完了条件に置く（標準 `principles/naming/unified-vocabulary.md`）。語彙も正本を一箇所に置く関心に含まれる（標準 `README.md` の「正本の単一」）。

配布する policy 本文を宣言から生成する設計（[ADR 0005](0005-generate-agent-policy-from-declarations.md)）では、生成器が宣言側の名と配布物側の見出しを繋ぐ。語が割れたままだと、その対応が生成器の内側に隠れた変換として残り、割れを固定してしまう。

候補は三つあった。宣言側の definition に寄せる形、`routing.nix` の agent に寄せる形、配布物と文書が使う subagent に寄せる形である。definition は委譲先という意味を持たず、client が持つ role 定義の file 形式を指す実装語である。agent は client との流用が解けない。

## Decision

委譲先の定義を指す語を `subagent` に統一する。`agent` は AI CLI を指す語として使わず、CLI は `client` と呼ぶ。

対象は、`agents/roles/` の名、`routing.nix` の `agentSkills` と `agentHandoffs` および要素の `agent` 欄、client contract の `definitions` 系 option、`agents.shared.definitions`、managed artifact の id の `definitions/` 接頭辞である。

## Consequences

宣言、配布物、文書、検査が同じ語で追跡できるようになり、生成器は語の変換を持たない。

`agents/fixtures/client-contract.json` は全 client の option を写したスナップショットであり、id 集合の一致検査とともに改名の影響を機械的に検出する。改名は評価時に落ちるため、取り残しは build で分かる。

`agents/` という unit 名は、client、subagent、policy を所有する unit の名として残す。
