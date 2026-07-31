# セキュリティ境界

**読み手:** 責務の境界と要素の関係を理解したい人。学習中に読む。

この構成は、Git checkout、Nix store、Linux user、root 管理領域、Docker、Windows、外部 service を別の信頼境界として扱う。通常の secret 編集は [Secrets](../operations/secrets.md)、host key の登録は [SOPS enrollment](../operations/sops-enrollment.md)、適用は [Rebuild](../operations/rebuild.md)を参照する。

## SOPS の鍵と暗号文

[`modules/secrets.nix`](../../modules/secrets.nix) は sops-nix の age key を `/var/lib/sops-nix/key.txt` に固定し、自動生成を無効にする。directory は root `0700`、key は root `0400` であり、通常ユーザーは鍵本文を読まない。doctor の root probe も owner、group、mode だけを返す。

host key は一台の runtime identity であり、別ホストへコピーしない。offline recovery key は host key と分離してホスト外に保管し、enrollment と復旧の間だけ接続する。repository の [`secrets/.sops.yaml`](../../secrets/.sops.yaml) は公開 recipient、[`secrets/secrets.yaml`](../../secrets/secrets.yaml) は暗号文を保持する。復号鍵は Git に置かない。

現行 source は `my.sops.enrollmentState = "migration"` であり、host key 分離の完了を宣言していない。この状態では doctor が旧 home key の残存を警告に留める。host key と recovery key の復号を実測し、home key を削除した後にだけ `enrolled` へ切り替える。

sops-nix は activation 時に暗号文を復号する。`sops.secrets` の secret file は `/run/secrets`、配備 path を指定しない template は `/run/secrets/rendered` に平文を生成する。agentmemory の環境ファイルは後者に属する。

Git identity の template は設定ユーザーの `~/.config/git/identity.conf` と、work identity を使う場合の `~/.config/git/work-identity.conf` を明示する。GitHub CLI の template も設定ユーザーの `~/.config/gh/hosts.yml` を明示する。sops-nix は mode `0600`、設定ユーザー所有の平文 target を runtime に生成し、これらの user-home path から参照させる。Nix 宣言には secret value ではなく placeholder を置くため、平文を Nix store の設定 artifact に含めない。各 secret file と template の owner、mode、その path を読める consumer process が secret ごとの信頼境界になる。

## GitHub credential

[`accounts/module.nix`](../../accounts/module.nix) は account ごとの username と PAT を SOPS secret として宣言する。sops-nix template は `hosts.yml` を mode `0600` で user home に配備し、GitHub MCP wrapper は runtime の secret file から PAT を読んで子 process の環境へ渡す。secret value と実 account username は Nix source、doctor manifest、文書へ転記しない。

PAT の権限は用途に必要な repository と operation に限定する。設定ユーザー、root、PAT を読む MCP process は credential の信頼境界に含まれる。`gh auth login` や `gh auth switch` で別の credential store を作らず、SOPS の宣言経路へ集約する。

## agentgateway

[`modules/mcp/gateway.nix`](../../modules/mcp/gateway.nix) の listener は port だけを指定し、client authentication と listen address の制限を設定していない。現行 runtime は認証なしで `*:8765` を listen する。各 AI CLI の接続 URL が `localhost` でも、listener 自体を loopback 限定と扱ってはならない。

8765/TCP へ到達できる process と network peer は、gateway が公開する MCP tool を呼べる信頼境界に入る。実際に Windows 側や外部 network から到達できるかは WSL の network mode、Windows Firewall、host 側の転送設定に依存する。gateway の deny rule は個別 tool の公開制御であり、client 認証の代わりにはならない。

agentgateway は設定ユーザーの systemd service として動き、stdio MCP front を同じ user 権限で起動する。front が読める checkout、home、runtime secret と、実行できる command が tool call の権限上限になる。gateway の bind または認証を変える場合は [`modules/mcp/gateway.nix`](../../modules/mcp/gateway.nix) を正本として見直す。

## Docker

[`modules/mcp/docker.nix`](../../modules/mcp/docker.nix) は backend の host port を `127.0.0.1:<port>:<port>` で publish する。これは agentgateway の `*:8765` とは異なる境界であり、backend port は host の非 loopback address へ直接 publish しない。container 間通信は専用の `mcp-backends` network を使う。

設定ユーザーは `docker` group に属する。Docker API を使える主体は container の起動、mount、inspect が可能であり、container 環境へ渡した secret も読める。Docker group、root、Docker daemon を backend secret と host filesystem の信頼境界に含める。

agentmemory の API key は SOPS template から Docker の environment file を経て container 環境に入る。agentmemory の session 内容は host volume に保存され、LLM 処理の対象は外部 provider へ送られる。

upstream OCI image は digest を Nix 宣言へ固定し、registry 取得を `dotfiles-sync-images` に限定する。container 起動時の暗黙 pull は無効である。同期と更新は [OCI images](../operations/oci-images.md)に従う。

## Codex sandbox

[`modules/clis/codex/config.toml`](../../modules/clis/codex/config.toml) は既定を `workspace-write`、network access を有効、approval policy を `never` とする。Codex の local command は sandbox 内で対話承認なしに実行される。

[`modules/clis/codex/default.nix`](../../modules/clis/codex/default.nix) は dotfiles checkout の project config に `.git` を追加の writable root として設定する。これにより repository 操作は可能になるが、workspace 外の任意 path を書き込み可能にはしない。project config は trusted project の範囲にだけ置く。

sandbox は gateway の client 認証、Docker daemon の権限、Windows interop の境界を代替しない。network access が有効なので、sandbox 内 process は到達可能な endpoint へ接続できる。MCP tool は gateway と各 server の user 権限、secret、backend 境界も合わせて評価する。

## Windows interop

[`modules/wsl.nix`](../../modules/wsl.nix) は WSLInterop を有効にし、Windows 側の固定 command を呼ぶ `wslview` を system closure に入れる。Linux process から Windows process を起動する時点で WSL の境界を越える。渡した URL、path、引数は Windows 側の process が処理する。

`appendWindowsPath = false` のため、Windows の executable directory を Linux の PATH へ自動追加しない。ただし固定 path を使う明示的な Windows command と `/mnt/c` の file access を無効にはしない。doctor は launcher の store source と Windows command の起動経路を検査するが、Windows application や Windows 側の file 権限までは保証しない。

## 境界一覧

| 境界 | 信頼する主体 | 境界を越えるデータ |
|---|---|---|
| Git と Nix store | checkout を変更できる user、Nix build | Nix source、暗号文、生成 artifact |
| root の SOPS 領域 | root、sops-nix activation | host identity、復号済み secret |
| user credential | 設定ユーザーと credential consumer | Git identity、PAT、CLI 設定 |
| agentgateway | 8765/TCP へ到達する client、gateway user | prompt、tool argument、tool result |
| Docker | root、docker group、daemon、container | backend request、volume data、環境 secret |
| 外部 provider | provider と通信経路 | agentmemory の処理対象 session |
| Windows interop | Linux 呼び出し元、Windows process | command argument、Windows filesystem data |

doctor は境界の一部について service 状態、file source、owner、mode、MCP lifecycle を観測するが、secret value、PAT scope、network firewall、Windows 側 policy、agentmemory の保存内容は検査しない。検査範囲と失敗時の調査は [Doctor](../operations/doctor.md)を参照する。
