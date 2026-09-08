# ADR 0013: Codex を MCP session として配るのをやめる

**読み手:** agent が別 client へ委譲する経路を判断する人と、Capability の境界を変える人。

## Status

Accepted

## Context

`agent-session` Capability は Codex CLI を `codex mcp-server` として gateway へ載せ、全 client から `codex` tool として呼べるようにしていた。狙いは、現在の client の subagent では足りない場合に、別 vendor の独立した agent session へ委譲することだった。

実測ではこの経路が働いていない。`dotfiles-doctor` の `mcp-target/codex` は fail のままで、原因は Codex CLI が未 login であり、probe が `api.openai.com` から 401 を受けることである。恒常的に fail する観測は doctor の出力を読み飛ばす習慣を作る。ADR 0012 で autoupdate の失敗を可視化した意図と正面から衝突する。

方針側でも既に非推奨だった。配布 policy は「現在の client の subagent で足りる役割分担には使わない」と書いている。主 client が OMP になり、subagent と `task` を持つ現在、この条件が成立する場面はほとんどない。Skill はどれもこの Capability を要求しておらず、tool の存在に依存する記述も repository に無い。

保持には固定費がかかる。systemd service 一つ、loopback port 8777、doctor 実行ごとに最大 120 秒と実 token を使う probe、専用 check の `mcp-codex-client-executable-contract` である。

候補は三つあった。Codex CLI に login して probe を通す案、target を残して probe だけ緩める案、MCP adapter を削除する案である。

一つ目は経路を生かすが、doctor を回すたびに外部 API へ課金する構造が残る。二つ目は観測を弱めて fail を隠す案であり、観測を強めてきた直近の判断と矛盾する。三つ目は固定費と恒常 fail の両方が消える。失うのは agent から programmatic に OpenAI 側 session を起動する経路だけで、Codex は client として残るため人が直接 `codex` を起動する経路は変わらない。

## Decision

`capabilities/agent-session/` を削除し、`codex` MCP target と `mcp-codex-client-executable-contract` check を廃止する。`dotfiles.capabilities.enabled` から `agent-session` を外す。

Codex の release install contract は `agents/clients/codex/module.nix` へ移す。この contract が Capability にあったのは、agent client 設定と MCP adapter という二つの consumer が `runtime.executable` を共有していたからである。adapter が消えると consumer は client だけになり、他の client と同じ所有者に戻る。

## Consequences

別 vendor の agent session へ agent から委譲する経路は無くなる。OMP の subagent は session model を共有するため、独立した model による対抗意見が必要な場合は人が Codex client を起動する。

MCP target は 9 個から 8 個になり、port 8777 が空く。doctor の恒常 fail が一つ減り、実行ごとの外部 API 課金も無くなる。

入口 Skill を持たない Capability は `browser-runtime` だけになる。これは他の Capability の依存であり、agent が直接使う Capability は無くなった。配布 policy の該当記述もそれに合わせる。

Codex を再び MCP として配る判断をする場合は、login 済みであることを前提にできるか、probe が課金を伴うことを受け入れられるかを先に決める。
