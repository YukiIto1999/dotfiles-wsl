# 0015. downstream の GET body を MCP session の生存基準にする

## 状態

Accepted

## 背景

agentgateway 1.3.1 は downstream の SSE response を `crates/agentgateway/src/mcp/handler.rs` の `messages_to_response` で組み立て、keepalive interval に `None` を渡す。tool call のない session の GET stream は無通信のまま残る。Claude Code 2.1.220 は無通信の GET を約 300 秒で閉じ、同じ session へ三回再接続した後に新しい initialize を送る。

`crates/agentgateway/src/mcp/session.rs` の `SessionEntry` は `last_access` を GET の開始時にしか更新しない。reaper は `last_access` からの経過だけで reap を決めるため、idle TTL を超えて読み続けている正常な GET stream も対象になる。gateway は session ごとに全 stdio target を spawn するので、切れた session が残ると process と file descriptor がそのまま積み上がる。

2026-07-29 の監査は `LimitNOFILE=1048576` を根拠に FD 上限を問題なしとしたが、これは hard 値だけで、実効値である `LimitNOFILESoft` は systemd 既定の 1024 だった。journal には `Too many open files (os error 24)` が記録されており、新しい initialize が HTTP 500 で失敗していた。

## 決定

session の生存基準を「最後に request が来た時刻」から「downstream が response body を保持しているか」へ移す。次の五つを不変条件とする。

第一に、pending の SSE stream は 15 秒ごとに SSE comment frame を返す。keepalive は JSON-RPC message ではなくコメントであり、protocol の意味を持たない。GET と POST の SSE response は同じ builder を通るため、両方に同じ interval がかかる。

第二に、response body が生存している GET stream は session を pin する。reaper の retain 条件を `active_streams > 0 || now - last_access < idle_ttl` とし、active stream がある entry は `last_access` の経過に関わらず残す。

第三に、idle の計測は body の終了時刻から始める。stream guard は `crate::http::DropBody` で body と lifetime を一致させ、drop 時に active count を一度減らして `last_access` を drop 時刻へ進める。keepalive frame 自体では `last_access` を更新しない。

第四に、明示 DELETE は即座に session を削除する。DELETE で map から消えた entry へ guard が後から drop されても、session を復活させない。

第五に、`LimitNOFILE` の引き上げは補助であり、session 解放の代替にしない。soft と hard をともに 4096 に固定するのは、修正が効くまでの間に accept が落ちないようにするための封じ込めである。doctor は soft/hard の実値が宣言と一致しない generation を失敗とする。

idle TTL は upstream 既定の 30 分へ戻す。4 時間へ延ばしていたのは reap による session 切断を避けるためだったが、active stream を pin する仕組みができたことで延長の理由がなくなった。

doctor manifest を version 5 にし、`TasksCurrent`、`MemoryCurrent`、`MemorySwapCurrent`、`LimitNOFILE`、`LimitNOFILESoft` と `MainPID` の file descriptor 数を `active.mcp.resources` として観測する。期待値を持つのは FD 上限だけで、その値は systemd 宣言から導く。tasks、memory、swap には実測前の上限を置かず、値を取得できないことだけを失敗にする。

## 検討した代替案

idle TTL の短縮だけを先に適用する案。active stream を pin する仕組みがない状態で TTL を 30 分にすると、30 分を超えて読み続けている正常な GET stream まで reap される。session 切断を増やすため不採用。

agentgateway 1.4.0 への更新で解決する案。1.4.0 の downstream SSE builder も keepalive に `None` を渡すため、version 更新は session lifecycle の修正にならない。endpoint 分離の前提としては必要だが、この問題の解にはならない。

`LimitNOFILE` の引き上げだけで対処する案。上限を上げても session あたりの process 数は変わらず、蓄積の速度が同じである以上、到達時刻を先送りするだけになるため単独では不採用。

## 影響

同じ session を保持している client は、5 分ごとの再接続でも新しい session を作らなくなる。session あたり 10 個の stdio front を spawn する現行構造のまま、process と FD の蓄積が止まる。

修正は `pkgs/agentgateway/mcp-downstream-lifecycle.patch` に持つ。patch は test を先に持ち、`doCheck` と `checkFlags = [ "downstream_lifecycle_" ]` で package build 時に三つの回帰を実行する。`flake.nix` の `agentgateway-session-lifecycle` check は配備する package と同じ derivation を build するため、test を迂回した別 package を使えない。

この ADR は単一 endpoint に全 target を畳み込む現行構造を変えない。endpoint の分離と、target ごとの常駐 HTTP front への移行は別の判断として扱う。

## 一次資料

- [MCP Streamable HTTP: GET による SSE stream と session termination](https://modelcontextprotocol.io/specification/2025-06-18/basic/transport#streamable-http)
- [systemd.exec: `LimitNOFILE` の soft:hard 表記](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Process%20Properties)
- [systemd.resource-control: `TasksCurrent` と `MemoryCurrent` が cgroup 単位であること](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html)
