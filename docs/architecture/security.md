# セキュリティ境界

**読み手:** 責務の境界と要素の関係を理解したい人。学習中に読む。

この構成は、Git checkout、Nix store、Linux user、root 管理領域、Docker、Windows、外部 service を別の信頼境界として扱う。通常の secret 編集は [Secrets](../operations/secrets.md)、host key の登録は [SOPS enrollment](../operations/sops-enrollment.md)、適用は [Rebuild](../operations/rebuild.md)を参照する。

## SOPS の鍵と暗号文

[`secrets/sops/module.nix`](../../secrets/sops/module.nix) は sops-nix の age key を `/var/lib/sops-nix/key.txt` に固定し、自動生成を無効にする。directory は root `0700`、key は root `0400` であり、通常ユーザーは鍵本文を読まない。

host key は一台の runtime identity であり、別ホストへコピーしない。offline recovery key は host key と分離してホスト外に保管し、enrollment と復旧の間だけ接続する。repository の [`secrets/sops/assets/.sops.yaml`](../../secrets/sops/assets/.sops.yaml) は公開 recipient、[`secrets/sops/assets/secrets.json`](../../secrets/sops/assets/secrets.json) は暗号文を保持する。復号鍵は Git に置かない。

sops-nix は activation 時に暗号文を復号する。`sops.secrets` の secret file は `/run/secrets`、配備 path を指定しない template は `/run/secrets/rendered` に平文を生成する。Hindsightの環境ファイルは後者に属し、client hookやMCP frontへは配らない。

Git identity の template は設定ユーザーの `~/.config/git/identity.conf` と、work identity を使う場合の `~/.config/git/work-identity.conf` を明示する。GitHub CLI の template も設定ユーザーの `~/.config/gh/hosts.yml` を明示する。[`secrets/sops/impl/user-secret-file.nix`](../../secrets/sops/impl/user-secret-file.nix) が user 所有と mode `0600` を固定し、[`identity/module.nix`](../../identity/module.nix) が username を渡して明示的に import する。sops-nix は平文 target を runtime に生成する。Nix 宣言には secret value ではなく placeholder を置くため、平文を Nix store の設定 artifact に含めない。各 secret file と template の owner、mode、その path を読める consumer process が secret ごとの信頼境界になる。

## GitHub credential

[`identity/module.nix`](../../identity/module.nix) は account ごとの username と PAT を SOPS secret として宣言する。sops-nix template は `hosts.yml` を mode `0600` で user home に配備し、GitHub MCP wrapper は runtime の secret file から PAT を読んで子 process の環境へ渡す。secret value と実 account username は Nix source、doctor 出力、文書へ転記しない。

HTTPS の Git は、`github.com` 全体で `gh` の credential helper を使い、primary の PAT を受け取る。store が owner の印を付けた account について、[`toolchain/git/module.nix`](../../toolchain/git/module.nix) は `https://github.com/<owner>` の helper を、その account の user 所有 `0400` の PAT file を読む helper へ置き換える。Git 設定と Nix store には PAT file の path だけが入り、PAT は remote URL、Git 設定、生成 artifact に書かない。helper は Git の保存と破棄の要求を無視し、SOPS 以外に credential の複製を作らない。

PAT の権限は用途に必要な repository と operation に限定する。設定ユーザー、root、PAT を読む MCP process と Git credential helper は credential の信頼境界に含まれる。`gh auth login` や `gh auth switch` で別の credential store を作らず、SOPS の宣言経路へ集約する。

## Git の追跡対象

[`toolchain/git/module.nix`](../../toolchain/git/module.nix) は global の `core.excludesFile` を `~/.config/git/ignore` に向け、[`toolchain/git/assets/ignore`](../../toolchain/git/assets/ignore) を正本として配備する。
この ignore は OS、editor、secret 用の一般的な file 名に加え、.NET、Rust、JavaScript/TypeScript、Python、JVM、CMake、Go、Swift、Dart、Ruby、Haskell、Elixir、R、Terraform の既定の生成物と local cache を除外する。
選定には [GitHub の gitignore templates](https://github.com/github/gitignore) を参照し、主に [Visual Studio](https://github.com/github/gitignore/blob/main/VisualStudio.gitignore)、[Rust](https://github.com/github/gitignore/blob/main/Rust.gitignore)、[Node](https://github.com/github/gitignore/blob/main/Node.gitignore) の生成物を採用する。
全 repository に適用するため、`bin/`、`build/`、`dist/`、`vendor/`、一般的な binary や archive の拡張子は一律に除外しない。
.NET の `bin/` は `Debug/` と `Release/` の下だけを除外し、独自の configuration や出力先は project の `.gitignore` に記す。
lockfile、Gradle wrapper、Yarn の patches、plugins、releases、Pixi の config は追跡できる状態を保つ。
project が生成物や cache を意図的に共有する場合は、その repository の `.gitignore` で対象の親 directory と内容を `!` で再包含する。
配備先はgenerationが持つstoreの複製であり、`dotfiles-rebuild`で反映する。checkoutの`toolchain/git/assets/ignore`だけを編集しても配備済みのignoreは変わらず、前のgenerationへ戻すと前の内容に戻る。Windows側のGitや設定を導入していないcloneには適用されない。
ignore は既に追跡した file には効かず、`git add -f` でも迂回できるため、secret の保護を file 名だけに任せない。

[`toolchain/git/assets/hooks/pre-commit`](../../toolchain/git/assets/hooks/pre-commit) は file 名によらず staged の追加行を検査する。
対象は GitHub token、age の標準鍵と post-quantum 鍵の秘密鍵形式、および `apikey_`、`sk-proj-`、`sk-ant-`、`sk-or-v1-` に英数字、`_`、`-` が 20 文字以上続く API token 形式に限る。
一致する追加行を含む commit は拒み、出力には対象の file 名と `secrets/sops/assets/secrets.json` への移動案内だけを含め、鍵本文や token 値を出さない。
公開 age recipient と、prefix だけを記す source は拒否しない。
未知の形式、分割や符号化した secret、既存の commit 履歴は検査せず、hook の上書きや `--no-verify` でも迂回できるため、全ての credential を検出する保証はない。
[`toolchain/git/fixtures/hooks.sh`](../../toolchain/git/fixtures/hooks.sh) は `age-keygen` で検証用の秘密鍵を実行時に生成し、実際の commit の拒否と、secret を staged から外して削除した後の commit を検査する。

## agentgateway

[`platform/mcp/gateway/module.nix`](../../platform/mcp/gateway/module.nix)のlistenerはportだけを指定し、client認証を設けない。
listenerのbind addressとは別に、systemd serviceの`IPAddressDeny=any`とloopbackの`IPAddressAllow`でcgroupの通信をloopbackに制限する。
設定した通信制限はserviceの境界であり、CLIの接続URLがlocalhostであることだけを制限の根拠にしない。

loopbackのgatewayとfrontへ到達できるprocessは、公開MCP toolを呼べる信頼境界に入る。
Windows側からの到達性はWSLのnetwork modeと転送経路にも依存し、doctorのservice検査だけでは外部到達性を証明しない。
gatewayのdeny ruleはtoolの公開制御であり、client認証の代わりにはならない。
gatewayとfrontは設定ユーザーのserviceとして動き、読めるcheckout、home、runtime secretと、実行できるcommandがtool callの権限上限になる。

## Docker

[`platform/containers/module.nix`](../../platform/containers/module.nix) と [`container-backend.nix`](../../platform/containers/impl/container-backend.nix) は、backend の host port を `127.0.0.1:<port>:<port>` で publish し、宣言された publish が loopback に閉じることを検査する。これは agentgateway の listener とは異なる境界であり、backend port は host の非 loopback address へ直接 publish しない。container 間通信は専用の `dotfiles-backends` network を使う。

設定ユーザーは `docker` group に属する。Docker API を使える主体は container の起動、mount、inspect が可能であり、container 環境へ渡した secret も読める。Docker group、root、Docker daemon を backend secret と host filesystem の信頼境界に含める。

HindsightのLLM credentialはSOPS templateからroot所有の`hindsight.env`へ展開し、Dockerのenvironment fileを経てcontainerだけへ渡す。Hindsightの原文書類はnamed volume `hindsight-data:/home/hindsight/.pg0`へ保存し、宣言で固定したmultilingual embedding/reranker modelはNix storeからread-onlyでmountする。APIはhostの`127.0.0.1:3111`、memory MCP frontは`127.0.0.1:8774`であり、gateway経由のclientはHindsightへ直接credentialを渡さない。
clientは会話のturnをretain対象にしない。retain対象は明示的な`memory_save`と、omp の session 記録から利用者の発言だけを外部modelへ渡して候補を選ぶ記憶の収穫である。既知のinjection blockを決定的に除外するが、secretやPIIをすべて検出する保証はないため、retain入力を安全な保管場所とは扱わない。原文書類はlocal volumeに残る一方、extraction inputは設定した外部LLMへ送られる。

SonarQubeのDB passwordはSOPS runtime templateからnative `POSTGRES_PASSWORD_FILE`とread-onlyの`sonar.properties`へ渡し、DockerのEnv/configへ値を保存しない。
MCPは読み取り用user token、新規scanは別のproject analysis tokenをprivate process environmentで使い、root、Docker group、credential readerを信頼境界に含める。
default groupの継承権限を含む初期設定と、解析sourceの送信条件は[code-quality](../reference/code-quality.md#runtime-と-credential)が所有する。

upstream OCI image は digest を Nix 宣言へ固定し、containerを有効にしたhostの`dotfiles-sync-images`にregistry取得を限定する。container起動時の暗黙pullは無効である。同期と更新は [OCI images](../operations/oci-images.md)に従う。

## Agent client の供給経路

[`agents/impl/contract.nix`](../../agents/impl/contract.nix) は client binary の供給を `installer-script` と `github-release` に分ける。Claude Code と Antigravity は HTTPS で取得した upstream installer を実行し、配備 layout も upstream が所有する。この経路では dotfiles が payload の digest、archive 構造、原子的な公開を検証しない。信頼対象は installer の配布元、TLS 経路、実行時の upstream script である。

Codex、OpenCode、OMP は GitHub release を dotfiles が管理する。GitHub API が返す SHA-256 digest と download 内容を一致させる。asset が archive の場合は、展開する前に member の path、type、件数、論理 size、重複、衝突を拒否する。OMP のように asset が単一の実行 file の場合は、展開すべき構造を持たないため、path 成分を持たない entrypoint として payload へ置く。以降はどちらも同じ経路で symlink、hard link、special file、owner、mode、required path を検査し、固定した directory descriptor から entrypoint の version probe を実行する。検証済み tree は digest を名前にした release directory へ置き、`current` と visible binary の相対 symlink を identity 比較付きの rename で切り替える。通常の失敗では EXIT trap が旧状態へ戻し、曖昧な object は削除せず残す。

単一実行 file の asset は、upstream の build 環境と loader の互換性に依存する。dotfiles は `programs.nix-ld` が供給する loader で entrypoint を probe し、probe を通らない release は公開しない。OMP の `config.yml` と `agent.db` は設定ユーザーだけが所有する可変状態であり、認証情報を Nix store や checkout へ取り込まない。

採用clientの更新は互いに独立で、一つの失敗は他clientの取得と公開を止めず、失敗したclient名を集約して非ゼロで終える。
自動更新を選んだclientだけがtimerから更新され、timerを採用した場合はdoctorで失敗を観測する。

この publish は同じ client root の lock を守る installer 同士を直列化する。同じ UID の悪意ある process が private name または固定済み inode を syscall 間で改変する攻撃までは防がない。`SIGKILL` や電源断では EXIT trap を実行できず、durable transaction journal もないため、途中状態からの自動 rollback は保証しない。これは受け入れている境界であり、更新後の release tree は `dotfiles-doctor` で観測する。

## Codex sandbox

[`agents/clients/codex/assets/config.toml`](../../agents/clients/codex/assets/config.toml) は既定の permission profile を `dev` とし、`:workspace` を継承して workspace roots、`~/projects`、`~/workspace` への書込と network access を許可する。approval policy は `never` なので、Codex の local command は profile の範囲内で対話承認なしに実行される。

[`agents/clients/codex/module.nix`](../../agents/clients/codex/module.nix) は同名の `dev` profile を system config と project config で拡張する。system config は agent runtime の cache と state、dotfiles checkout の project config はその `.git` だけを書込対象に加える。permission profile と旧 `sandbox_mode`、`sandbox_workspace_write` は混在させない。
subagent は親 session の permission profile を継ぐ。Codex の subagent override が運ぶのは model、reasoning、instructions、personality、service tier、feature 無効化、skill 選択だけであり、subagent file の `default_permissions` は読み捨てられる。read-only の subagent 定義にも独自の sandbox 境界はない。
既存の user config に旧 top-level key が残る場合だけ、Home Manager activation が未知の設定を保持したまま `dev` profile へ一度移行する。移行は同一 directory 内の temporary file を検証してから原子的に置換する。symlink、non-regular file、不正 TOML は変更せず activation を失敗させる。

agent runtime の共有 cache は user 所有の directory `0700` と marker file `0600` で識別する。launcher と GC は同じ `gc.lock` を取り、共有 cache の型、所有者、symlink、mode、marker を検証する。GC は lock の下で rename だけを行い、計測と削除を lock の外で行う。削除する entry は同じ filesystem の `trash` へ rename してから消すので、lock を待つ launcher が削除の長さに従属しない。GC が allocated bytes 基準で共有 cache を空にするのは、使われていない Cargo の unit を先に回収しても容量上限を超え、active agent session が一件もない場合に限る。
GC は trash 内の自分が所有する directory にだけ読取・書込・実行権限を戻し、read-only の一時 directory も削除する。
その際に symlink は辿らず、別の所有者の directory の権限は変更しない。
Cargo の build-dir の root も user 所有の directory `0700` であり、symlink や別の所有者の root では launcher は起動を拒み、GC は失敗する。
共有 cache を空にしても、48 時間の保護と lock で見送った unit で上限を超えるだけなら、GC は残った量を記録して成功で終え、次の実行に回す。
それらの unit を除いても上限を超える場合だけ、人の手が要る状態として失敗する。
GC は Cargo の build-dir を unit ごとに回収し、Cargo が build の間に握る `.cargo-build-lock` か `.cargo-lock` の flock を自分も取れた entry だけを触り、rename の間その lock を保持する。
GC は Cargo の lock を取った後にその entry を走査し直し、回収を決めた後に最終使用か member の inode が変わった unit は回収しない。
走査の後に別の build がその unit を使ったことを、lock を取る前の結果のまま見落とさないためである。
lock を待つ Cargo は開いた lock file の inode を lock するので、GC は lock file と profile の directory を動かさず、unit の fingerprint と成果物だけを `trash` へ移す。
Cargo は test の実行前に lock を解くので、GC は最終使用が直近 48 時間以内の unit、成果物、incremental の directory を、lock を取れても回収しない。
Cargo は invocation の開始時に unit の hash file を読み、relatime はその atime を最大 24 時間古いまま残すので、48 時間は 24 時間までの invocation が使う unit を守る幅である。
test runner は Cargo を介さず test binary を実行し fingerprint を読まないので、GC は unit の最終使用を fingerprint と成果物のすべての file の atime と mtime から測る。
GC は Cargo の lock を取った後、entry を走査し直す時点で `/proc/*/exe` を調べ、entry の中の file を実行している process があればその entry を丸ごと見送る。
test は実行中に別の unit の `OUT_DIR` を読むので、実行中の file の unit だけを残すのでは足りない。
GC を始めた時点で一度だけ調べると、その後に始まった test を見落とすので、lock を取った entry ごとに調べる。
調べてから rename を終えるまでに始まった実行は、成果物の最終使用が 48 時間以内でない限り守れない。
atime を更新しない mount では Cargo の使用が見えないので、GC は unit を回収せずに失敗する。
launcher は build-dir に触れないので、GC は unit の rename に `gc.lock` を取らない。

sandbox は gateway の client 認証、Docker daemon の権限、Windows interop の境界を代替しない。network access が有効なので、sandbox 内 process は到達可能な endpoint へ接続できる。MCP tool は gateway と各 server の user 権限、secret、backend 境界も合わせて評価する。

## Windows interop

[`workstation/wsl/module.nix`](../../workstation/wsl/module.nix)はWSLInteropを有効にし、単一URLまたはpathをWindowsへ渡す`wslview`を配備する。
Windows PowerShellの場所はhost optionで指定し、Linux processから起動するときにWSLの境界を越える。
targetはUTF-8のBase64として渡し、PowerShell codeや追加application引数として評価しない。
Linux pathはwslpathでWindows pathへ変換し、関連付けられたWindows applicationへ起動要求を送る。
要求の終了status 0は、applicationの表示成功を保証しない。

`appendWindowsPath = false` のため、Windows の executable directory を Linux の PATH へ自動追加しない。ただし固定 path を使う明示的な Windows command と `/mnt/c` の file access を無効にはしない。doctor は launcher の store source と Windows command の起動経路を検査するが、Windows application や Windows 側の file 権限までは保証しない。

## 境界一覧

| 境界 | 信頼する主体 | 境界を越えるデータ |
|---|---|---|
| Git と Nix store | checkout を変更できる user、Nix build | Nix source、暗号文、生成 artifact |
| root の SOPS 領域 | root、sops-nix activation | host identity、復号済み secret |
| user credential | 設定ユーザーと credential consumer | Git identity、PAT、CLI 設定 |
| agentgateway と front | loopback の port へ到達する client、service user | prompt、tool argument、tool result |
| Docker | root、docker group、daemon、container | backend request、volume data、環境 secret |
| 外部 provider | provider と通信経路 | Hindsightのextraction input、LLM処理対象のretain内容 |
| Windows interop | Linux 呼び出し元、Windows process | command argument、Windows filesystem data |

doctor は境界の一部について service 状態、file source、owner、mode、MCP lifecycle を観測するが、secret value、PAT scope、network firewall、Windows 側 policy、Hindsightの保存内容やLLM retention結果は検査しない。health/readinessが成功しても、LLMが利用できることやretainが保存済みであることは示さない。検査範囲と失敗時の調査は [Doctor](../operations/doctor.md)を参照する。
