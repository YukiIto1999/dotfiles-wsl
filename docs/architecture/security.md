# セキュリティ境界

**読み手:** 責務の境界と要素の関係を理解したい人。学習中に読む。

この構成は、Git checkout、Nix store、Linux user、root 管理領域、Docker、Windows、外部 service を別の信頼境界として扱う。通常の secret 編集は [Secrets](../operations/secrets.md)、host key の登録は [SOPS enrollment](../operations/sops-enrollment.md)、適用は [Rebuild](../operations/rebuild.md)を参照する。

## SOPS の鍵と暗号文

[`sops/module.nix`](../../sops/module.nix) は sops-nix の age key を `/var/lib/sops-nix/key.txt` に固定し、自動生成を無効にする。directory は root `0700`、key は root `0400` であり、通常ユーザーは鍵本文を読まない。

host key は一台の runtime identity であり、別ホストへコピーしない。offline recovery key は host key と分離してホスト外に保管し、enrollment と復旧の間だけ接続する。repository の [`sops/assets/.sops.yaml`](../../sops/assets/.sops.yaml) は公開 recipient、[`sops/assets/secrets.yaml`](../../sops/assets/secrets.yaml) は暗号文を保持する。復号鍵は Git に置かない。

sops-nix は activation 時に暗号文を復号する。`sops.secrets` の secret file は `/run/secrets`、配備 path を指定しない template は `/run/secrets/rendered` に平文を生成する。agentmemory の環境ファイルは後者に属する。

Git identity の template は設定ユーザーの `~/.config/git/identity.conf` と、work identity を使う場合の `~/.config/git/work-identity.conf` を明示する。GitHub CLI の template も設定ユーザーの `~/.config/gh/hosts.yml` を明示する。[`sops/impl/user-secret-file.nix`](../../sops/impl/user-secret-file.nix) が user 所有と mode `0600` を固定し、[`accounts/module.nix`](../../accounts/module.nix) が username を渡して明示的に import する。sops-nix は平文 target を runtime に生成する。Nix 宣言には secret value ではなく placeholder を置くため、平文を Nix store の設定 artifact に含めない。各 secret file と template の owner、mode、その path を読める consumer process が secret ごとの信頼境界になる。

## GitHub credential

[`accounts/module.nix`](../../accounts/module.nix) は account ごとの username と PAT を SOPS secret として宣言する。sops-nix template は `hosts.yml` を mode `0600` で user home に配備し、GitHub MCP wrapper は runtime の secret file から PAT を読んで子 process の環境へ渡す。secret value と実 account username は Nix source、doctor 出力、文書へ転記しない。

PAT の権限は用途に必要な repository と operation に限定する。設定ユーザー、root、PAT を読む MCP process は credential の信頼境界に含まれる。`gh auth login` や `gh auth switch` で別の credential store を作らず、SOPS の宣言経路へ集約する。

## agentgateway

[`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) の listener は port だけを指定し、client authentication と listen address の制限を設定していない。現行 runtime は認証なしで gateway の port を listen する。各 AI CLI の接続 URL が `localhost` でも、listener 自体を loopback 限定と扱ってはならない。

gateway の port へ到達できる process と network peer は、gateway が公開する MCP tool を呼べる信頼境界に入る。front の port も loopback で listen するので、同じ境界に入る。実際に Windows 側や外部 network から到達できるかは WSL の network mode、Windows Firewall、host 側の転送設定に依存する。gateway の deny rule は個別 tool の公開制御であり、client 認証の代わりにはならない。

agentgateway と各 front は設定ユーザーの systemd service として動く。front が読める checkout、home、runtime secret と、実行できる command が tool call の権限上限になる。gateway の bind または認証を変える場合は [`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) を正本として見直す。

## Docker

[`containers/module.nix`](../../containers/module.nix) と [`container-backend.nix`](../../containers/impl/container-backend.nix) は、backend の host port を `127.0.0.1:<port>:<port>` で publish し、宣言された publish が loopback に閉じることを検査する。これは agentgateway の listener とは異なる境界であり、backend port は host の非 loopback address へ直接 publish しない。container 間通信は専用の `dotfiles-backends` network を使う。

設定ユーザーは `docker` group に属する。Docker API を使える主体は container の起動、mount、inspect が可能であり、container 環境へ渡した secret も読める。Docker group、root、Docker daemon を backend secret と host filesystem の信頼境界に含める。

agentmemory の API key は SOPS template から Docker の environment file を経て container 環境に入る。agentmemory の session 内容は host volume に保存され、LLM 処理の対象は外部 provider へ送られる。

upstream OCI image は digest を Nix 宣言へ固定し、registry 取得を `dotfiles-sync-images` に限定する。container 起動時の暗黙 pull は無効である。同期と更新は [OCI images](../operations/oci-images.md)に従う。

## Agent client の供給経路

[`agents/impl/contract.nix`](../../agents/impl/contract.nix) は client binary の供給を `installer-script`、`github-release`、`nix-package` に分ける。Claude Code と Antigravity は HTTPS で取得した upstream installer を実行し、配備 layout も upstream が所有する。この経路では dotfiles が payload の digest、archive 構造、原子的な公開を検証しない。信頼対象は installer の配布元、TLS 経路、実行時の upstream script である。

OMPはupstream flakeのsource revisionとNAR hashを`flake.lock`に固定し、upstreamが定義するNix buildとnix-community binary cacheを信頼する。OMPの`config.yml`と`agent.db`は設定ユーザーだけが所有する可変状態であり、認証情報をNix storeやcheckoutへ取り込まない。

Codex と OpenCode は GitHub release を dotfiles が管理する。GitHub API が返す SHA-256 digest と download 内容を一致させ、archive を展開する前に member の path、type、件数、論理 size、重複、衝突を拒否する。展開後は symlink、hard link、special file、owner、mode、required path を検査し、固定した directory descriptor から entrypoint の version probe を実行する。検証済み tree は digest を名前にした release directory へ置き、`current` と visible binary の相対 symlink を identity 比較付きの rename で切り替える。通常の失敗では EXIT trap が旧状態へ戻し、曖昧な object は削除せず残す。

この publish は同じ client root の lock を守る installer 同士を直列化する。同じ UID の悪意ある process が private name または固定済み inode を syscall 間で改変する攻撃までは防がない。`SIGKILL` や電源断では EXIT trap を実行できず、durable transaction journal もないため、途中状態からの自動 rollback は保証しない。これは受け入れている境界であり、更新後の release tree は `dotfiles-doctor` で観測する。

## Codex sandbox

[`agents/codex/assets/config.toml`](../../agents/codex/assets/config.toml) は既定の permission profile を `dev` とし、`:workspace` を継承して workspace roots、`~/projects`、`~/workspace` への書込と network access を許可する。approval policy は `never` なので、Codex の local command は profile の範囲内で対話承認なしに実行される。

[`agents/codex/module.nix`](../../agents/codex/module.nix) は同名の `dev` profile を system config と project config で拡張する。system config は agent runtime の cache と state、dotfiles checkout の project config はその `.git` だけを書込対象に加える。permission profile と旧 `sandbox_mode`、`sandbox_workspace_write` は混在させない。
subagent は親 session の permission profile を継ぐ。Codex の agent role override が運ぶのは model、reasoning、instructions、personality、service tier、feature 無効化、skill 選択だけであり、role file の `default_permissions` は読み捨てられる。read-only の agent definition にも独自の sandbox 境界はない。
既存の user config に旧 top-level key が残る場合だけ、Home Manager activation が未知の設定を保持したまま `dev` profile へ一度移行する。移行は同一 directory 内の temporary file を検証してから原子的に置換する。symlink、non-regular file、不正 TOML は変更せず activation を失敗させる。

agent runtime の共有 cache は user 所有の directory `0700` と marker file `0600` で識別する。launcher と GC は同じ `gc.lock` を取り、共有 cache の型、所有者、symlink、mode、marker を検証する。GC が allocated bytes 基準で共有 cache を空にするのは、inactive project cache を先に回収しても容量上限を超え、active agent session が一件もない場合に限る。

sandbox は gateway の client 認証、Docker daemon の権限、Windows interop の境界を代替しない。network access が有効なので、sandbox 内 process は到達可能な endpoint へ接続できる。MCP tool は gateway と各 server の user 権限、secret、backend 境界も合わせて評価する。

## Windows interop

[`host/module.nix`](../../host/module.nix) は WSLInterop を有効にし、Windows 側の固定 command を呼ぶ `wslview` を system closure に入れる。Linux process から Windows process を起動する時点で WSL の境界を越える。渡した URL、path、引数は Windows 側の process が処理する。

`appendWindowsPath = false` のため、Windows の executable directory を Linux の PATH へ自動追加しない。ただし固定 path を使う明示的な Windows command と `/mnt/c` の file access を無効にはしない。doctor は launcher の store source と Windows command の起動経路を検査するが、Windows application や Windows 側の file 権限までは保証しない。

## 境界一覧

| 境界 | 信頼する主体 | 境界を越えるデータ |
|---|---|---|
| Git と Nix store | checkout を変更できる user、Nix build | Nix source、暗号文、生成 artifact |
| root の SOPS 領域 | root、sops-nix activation | host identity、復号済み secret |
| user credential | 設定ユーザーと credential consumer | Git identity、PAT、CLI 設定 |
| agentgateway と front | loopback の port へ到達する client、service user | prompt、tool argument、tool result |
| Docker | root、docker group、daemon、container | backend request、volume data、環境 secret |
| 外部 provider | provider と通信経路 | agentmemory の処理対象 session |
| Windows interop | Linux 呼び出し元、Windows process | command argument、Windows filesystem data |

doctor は境界の一部について service 状態、file source、owner、mode、MCP lifecycle を観測するが、secret value、PAT scope、network firewall、Windows 側 policy、agentmemory の保存内容は検査しない。検査範囲と失敗時の調査は [Doctor](../operations/doctor.md)を参照する。
