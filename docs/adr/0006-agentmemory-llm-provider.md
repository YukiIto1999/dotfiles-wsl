# 0006. agentmemory の LLM provider

## 状態

Accepted

## 背景

[ADR 0005](0005-agentmemory-lifecycle-hooks.md)では agentmemory を noop mode で開始し、
観測記録、BM25 検索、セッション冒頭の記憶注入を先に配備した。noop mode では
要約、reflect、consolidation が動かないため、これらを処理する LLM provider が必要になった。

API key を Nix の文字列として設定すると、評価結果や derivation を通じて Nix store に残る。
秘密値は SOPS の暗号文から activation 時に復号し、実行時だけコンテナへ渡す必要がある。

## 決定

OpenCode Go の OpenAI 互換 endpoint `https://opencode.ai/zen/go/v1` を LLM provider として使う。
model は `minimax-m2.7`、embedding provider は `none` とする。要約、reflect、consolidation は
この provider で処理する。

API key は `opencode/go_api_key` として SOPS で管理する。sops-nix template が runtime の
環境ファイルを生成し、`environmentFiles` が agentmemory コンテナへ渡す。Nix の設定には
placeholder だけを置き、API key を Nix store に含めない。template が変わったときは
`docker-agentmemory.service` を再起動する。

## 影響

要約、reflect、consolidation の処理対象となる prompt と session 内容は OpenCode Go へ送られる。
これらには private code や secret が含まれる可能性がある。本決定は、この内容が外部 provider へ
送られる境界を受け入れる。

embedding provider は `none` のため、embedding の生成と外部送信は行わない。API key は
リポジトリでは `secrets/secrets.yaml` の SOPS 暗号文として保持する。
agentmemory 0.9.26 の `config-flags` は `EMBEDDING_PROVIDER` の値が存在するだけで
embedding を有効と表示するため、`none` でも表示上は有効になる。実際の provider は生成されず、
検索は BM25-only mode で動く。この診断表示は agentmemory 更新時に再確認する。
`sops.secrets."opencode/go_api_key"` の宣言により、activation 時に復号済み secret file
`/run/secrets/opencode/go_api_key` が生成される。sops-nix template は placeholder を展開し、
rendered env file `/run/secrets/rendered/agentmemory.env` を生成する。ローカルの Nix 評価では、
どちらのファイルも UID 0、GID 0、mode `0400` である。`environmentFiles` は rendered env file を
Docker に渡し、API key はコンテナの環境変数に入る。API key が存在する経路は SOPS 暗号文、
復号済み secret file、rendered env file、コンテナの環境変数である。Docker API へアクセスできる
主体は container inspect で API key を読める。この権限を API key へのアクセス権として扱う。
