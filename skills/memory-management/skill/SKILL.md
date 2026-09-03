---
name: memory-management
description: Recalls and admits durable project memory through the configured Memory MCP. Use before work whose outcome may depend on prior project decisions, history, or lessons, and when a verified correction, settled policy, or reusable pattern may warrant explicit saving. Verifies recalled leads against primary sources and excludes sensitive, speculative, or transient content. Does not treat memory as a source of truth, replace repository research, or maintain task notes.
---

# Project memoryを扱う

`memory`は過去の候補を取得し、長期記憶を保存する実行手段である。呼ぶか、結果を採用するか、保存に値するかはagentが判断する。tool callの成功を成果としない。

自動captureの有無にかかわらず、必要なrecallとsaveはこの手順で明示的に行う。`project`は`git rev-parse --show-toplevel`が返すpathのbasenameとし、絶対pathやremote URLを識別子にしない。git top-levelを確定できない場合は保存しない。

## Recall

1. 編集や判断を始める前に、過去のdecision、経緯、lessonが今回の制約や選択を変え得るか判断する。過去との関係がないtaskでは呼ばない。
2. taskの語、安定した概念名、module名、repository相対path、知りたい理由を短いqueryにする。既知の対象を引くときは`memory_recall`、表現やsessionが不明で複数概念を横断するときは`memory_smart_search`を使う。
3. 結果を結論ではなく探索の手掛かりとして読む。今回のtaskに影響するclaim、そのscope、記録時点、source locator、memory IDだけを取り出す。空の検索結果を「過去に決定がない」証拠にしない。
4. 有力な結果だけを検証する。関連しない記録を増やすための広い検索や、同じqueryの反復をしない。

## Verification

採用すれば実装、方針、互換性、または利用者への回答が変わるclaimは、先に`memory_verify`でprovenanceを辿り、その後に一次sourceを直接読む。provenanceのconfidenceや過去sessionの記述だけでは検証済みとしない。

一次sourceは、現在のrepositoryにあるcode、test、configuration、受理済みdecision record、原issue・PR・commit、または今回の利用者指示である。対象project、revision、時点、適用scopeを照合する。現行の一次sourceまたは今回の利用者指示と矛盾するmemoryは採用せず、古い記録として扱う。sourceへ到達できないclaimは未検証のまま判断とsaveから除外する。

## Save admission

`memory_save`へ進めるのは、一次sourceで確認でき、将来のtaskでも判断を変える次のいずれかだけである。

- **訂正**: 既存の記録が誤りまたは陳腐化しており、置き換える内容と根拠が確定した。
- **確定方針**: proposalや暫定案ではなく、受理されたdecisionまたはpolicyとして正本に残っている。
- **再利用pattern**: 一回限りの手順ではなく、適用条件、scope、期待結果を説明でき、根拠となる実例がある。

保存文は一件につき一つのclaimに絞り、結論、適用条件、scope、一次sourceのrepository相対locatorを自立して読める形で含める。`project`にはgit top-levelのbasenameを渡す。大きなdiff、会話全文、command出力を転載しない。memoryだけが唯一の根拠になる内容は保存しない。

## Privacy

secret、credential、token、API key、private key、個人情報は、query、保存文、concept、file locatorのいずれにも渡さない。失効済みの値や一部を伏せた値も保存対象にしない。sourceに含まれる場合は値を除いても意味が保てる非機密の結論だけを記述し、保てなければrecallまたはsaveを行わない。

未検証の推測、仮説、未採用案、短期taskのplan・progress・TODO、一時path、現在だけ有効なbuild/test結果も保存しない。

## Failure

`memory`がunavailable、timeout、認証失敗、またはserver errorになった場合は、失敗したoperationと未取得・未保存であることを現在のtask記録に残し、localの正本を読んで作業を続ける。argument errorはschemaに従って一度だけ修正できるが、同じcallを同じargumentsで繰り返さない。失敗したsaveの代わりにrepositoryへ独自のmemory fileを作らない。

## 停止条件

- relevantなclaimを一次sourceで確認または棄却し、追加結果がtaskの制約を変えなくなったらrecallを止める。
- 最初の結果が空または無関係なら、異なる具体的anchorがある場合だけ一度queryを組み直す。それでも得られなければlocalの正本へ移る。
- 一次source、正しいproject、save admission、privacyのいずれかを満たせない候補は保存せずに止める。
- MCP failureを記録した後は、同じoperationの再試行loopに入らない。

## Non-goals

- memoryをsource of truth、承認記録、または現行repository状態の証明にすること。
- raw local exact search、LSP、Git history、Web調査、一次sourceの読解を置き換えること。
- scratchpad、task tracker、session log、command output置き場として使うこと。
- 自動capture、retention、削除、knowledge graph、team syncを運用すること。
- 未確定の設計やpolicyをこのSkill内で決定すること。
