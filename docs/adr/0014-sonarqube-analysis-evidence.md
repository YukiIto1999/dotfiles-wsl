# ADR 0014: SonarQubeを補助的な静的解析証拠として配備する

## Status

Accepted

## Context

SonarQubeの廃止時は、解析結果と現在のsourceを対応付ける条件にGit revisionの一致を使っていた。
しかし、SHAが異なっても指摘の条件が現在のfileに残る場合があり、同じSHAでも未commitの編集によって条件が消える場合がある。
運用経路の不足を製品の不要性と同一視せず、利用者の復旧指示に従って、結果の取得と現在への適用判断を接続し直す。

言語別のbuildとlintへ解析を置くだけでは、SonarQubeのproject別quality gate、解析履歴、保存sourceと指摘の閲覧を代替しない。
反対に、SonarQubeを全repositoryのverifyの必須条件にすると、serverの稼働とsource送信を一般の検証へ持ち込む。
既存のrepository内analyzerを維持し、必要なreviewにだけSonarQubeの証拠を渡す方式を選ぶ。

## Decision

`code-quality` CapabilityがSonarQube、内部PostgreSQL、公式SonarSource MCP、native scannerへのadapterとcredentialを所有する。
共通のcontainer、MCP front、CLI、SOPS、healthの入口を使い、廃止されたnpm MCP実装や独自tool APIは復活させない。
実装、取得snapshot、licenseと運用条件は[Capabilityの契約](../reference/code-quality.md)に置く。

`code-quality` Skillは証拠の取得、明示的に許可された新規scan、現在sourceへの適用判断を担当する。
通常の`code-review`は原版のStandards/Spec workflowを保ち、callerが必要な証拠bundleをaxis briefへ渡す。
reviewerの権限を広げず、providerが使えない場合も不足を記録してsource reviewを続ける。

Git revisionは出典情報であり、解析結果の正本や鮮度判定の唯一の条件にしない。
解析入力の内容、設定、profile/analyzer、analysis/task ID、解析日時、取得時点を区別し、指摘の対象条件を現在のsourceで確認する。
保存済みissuesと指定analysis IDのgateが同じ解析を指す根拠がなければ、別々の観測として返す。
過去のgateや取得時刻の新しさを、現在sourceの検証成功へ読み替えない。

MCPは専用evidence userの読み取り用User tokenを使い、新規scanは別のproject analysis tokenを使う。
default groupの継承権限も確認し、読み取り用userへAdminister、Execute Analysis、issue変更権限を常設しない。
DB passwordはnative secret fileとSonarのproperties fileへ注入し、DockerのEnv/configやNix storeへ値を保存しない。

upstreamの対応version、license、公式MCPの取得契約、credential注入、解析入力の対応条件が変わった場合は、Capability ownerが採用条件を再評価する。
常駐資源は宣言上限だけで可否を決めず、実際の解析負荷と同時利用下のRAM・CPUを測り、この環境の運用条件との適合を判断する。
目的に必要な証拠を取得できない状態、保守不能な配布・license条件、運用資源との不適合が続く場合は、ownerが代替と撤退を判断する。
SHAの相違、一時的な障害、Skillへの接続不足を撤退条件へ読み替えず、配備・呼出し側の不備を先に修正する。
撤退する場合も、ownerがDB・解析履歴・credential・Skillとcallerの導線の扱いを決め、明示的な判断なしにvolumeを削除しない。

## Consequences

server、DB、MCPの常駐資源と永続dataの保守が再び必要になるが、全projectのscanを一般の検証の前提にはしない。
sourceの送信範囲、scanner設定、profile/gate、projectごとの分析tokenと権限はproject ownerが決める。
言語別analyzerと閾値の正本は引き続きarchitecture-standardが所有する。

旧named volumeは廃止後に削除済みであり、この復旧は新instanceの機能復旧である。
設定のGit/Nix rollbackから旧DBや解析履歴は復元できず、実backupが確認できた場合に限って別途復元範囲を判断する。
