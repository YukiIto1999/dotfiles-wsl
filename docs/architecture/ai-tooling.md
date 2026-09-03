# AI tooling

**読み手:** 責務の境界と要素の関係を理解したい人。学習中に読む。

AI CLI の binary、共通資材、MCP 接続は別の経路で配備する。upstream installer と release で入れる binary は `~/.local/bin` の可変物、OMP は flake lock に固定した Nix package である。rules、skills、agents、managed config と MCP service は NixOS generation が宣言する。対象の追加や変更箇所は[変更箇所](../reference/change-map.md)を参照する。

## 配備の流れ

```text
agents/shared/AGENTS.md ─────────────────┐
agents/shared/definitions/*.md ─ client変換 ─┤
agents/shared/skills/* ──────────────────┼─ Nix store ──► 各 client の設定領域
flake input の plugin skills ────────────┘

AI CLI ── HTTP /mcp ──► agentgateway ── HTTP ──► MCP front (target ごと)
      │                                              ├─ service lifecycle ─► 共有 stdio server
      │                                              └─ session lifecycle ─► session ごとの stdio server
      ├── LSP ──► language server (PATH 上の binary)
      └── OTLP ──► telemetry collector
```

[`agents/module.nix`](../../agents/module.nix) の `dotfiles.agents` が、共有 source、各 client の capability、配備先、gateway fragment、最終 managed file、入手方法を型付き contract として定義する。[`flake.nix`](../../flake.nix) は account、agent client、container application、MCP provider、language server の required roster を default なしで宣言する。通常構成と gateway port variant のどちらでも提供集合との完全一致を求め、空集合、未知、欠落、余分な ID を評価時に拒否する。

### Client binary の更新

client contract は三種類の供給経路を持つ。`dotfiles-install-agents` は Claude Code と Antigravity の upstream installer、Codex と OpenCode の GitHub release を更新する。OMP は Bun/Rust native addon を含む upstream の Nix package を `flake.lock` に固定し、system rebuild で更新するため installer manifest と日次更新から除外する。GitHub release の asset、architecture ごとの entrypoint、`requiredPaths`、`retainedReleases` は各 client module の一つの `install` contract に置く。

GitHub release 経路は GitHub API の SHA-256 digest と取得した archive を照合し、member 名、type、件数、論理 size、重複、path 衝突を展開前に検査する。展開後は owner、mode、link、entrypoint と required path を調べ、隔離した環境で version probe を通した tree だけを公開する。

管理対象の release は `~/.local/share/dotfiles/agents/<client>/releases/sha256-<digest>` に置く。`current` は同じ client root 内の相対 symlink、`~/.local/bin/<binary>` は `current` 内の entrypoint を指す相対 symlink である。Codex の full package では `bin/codex` と `bin/codex-code-mode-host`、`codex-path/rg`、`codex-resources/bwrap`、`codex-package.json` を一つの release tree として検証する。OpenCode は archive 内の単一 entrypoint を同じ release lifecycle で扱う。どちらも管理済み release を 2 世代まで保持する。

公開処理は lock と固定した directory descriptor の下で release、`current`、visible symlink の identity を照合する。通常の失敗では切替前の状態へ戻し、変更または所有を確認できない object は削除しない。操作と確認方法は [Agent client の更新](../operations/agent-clients.md)に分ける。

Claude Code、Codex、OMP、OpenCode は、Home Manager が `~/.local/bin` より前へ置く共通 runtime wrapper から起動する。wrapper は実体を移動せず、upstream binary または OMP の Nix store executable を絶対 path で実行する。Antigravity は同じ CLI 起動境界を持たないため対象外である。

runtime は session ID、owner process、boot ID、管理下 `TMPDIR` を記録する。`CARGO_HOME` と `XDG_CACHE_HOME` が未設定なら、それぞれ `~/.cache/dotfiles-wsl/shared/cargo-home` と `~/.cache/dotfiles-wsl/shared/xdg-cache` を全 project、全 client で共有する。明示値は空文字列も含めて変更しない。

Git repository では git common directory から project ID を作り、linked worktree 間で `~/.cache/dotfiles-wsl/builds/<project-id>/cargo-target` を共有する。明示された `CARGO_TARGET_DIR` と project 固有の Cargo `target-dir` は上書きしない。GC は project cache と共有 cache の allocated bytes 合計が 64GiB を超えた場合に動き、30 日未使用の project cache、LRU 順の inactive project cache を先に削除する。それでも上限を超え、active agent session が一件もない場合だけ共有 cache を空にし、再計測後も上限を超えれば失敗する。active project cache で超過が残る場合は回収と失敗の対象にしない。symlink、所有者、型、marker を確認できない managed cache があれば、どの cache も削除せず失敗する。

`dotfiles-agent-verify` は HEAD、tracked diff、non-ignored untracked content、command、環境全体から fingerprint を作る。同一 fingerprint の成功だけを再利用し、raw 環境値は保存しない。agent 内の Nix shim は明示 out-link がない `nix build` と `nix-build` へ no-link option を加え、Nix store を pin する `result*` symlink の増殖を防ぐ。

agent 内の `git worktree add` は [`agents/impl/resource/`](../../agents/impl/resource) の `dotfiles-agent-worktree` へ接続し、新規 linked worktree を session 台帳へ登録する。終了時と hourly reaper は、台帳所有、clean、HEAD 不変、利用中 process なしを再確認した worktree だけを削除する。既存、dirty、commit 済み、所有者不明の worktree は自動削除しない。

この root は agent client 専用である。agent ではない CLI に共通の契約と配備が必要になった時点で、別の root `clis/` を作る。現在は該当する CLI がないため、空の分類は置かない。

## 共通 rules、agent、skill

[`agents/shared/AGENTS.md`](../../agents/shared/AGENTS.md) は全 client へ配る共通 rules の正本である。Home Manager が client ごとの規定 path に同じ immutable source を配備する。

静的 agent の正本は [`agents/shared/definitions/`](../../agents/shared/definitions) に置く。Claude Code は Markdown をそのまま使い、Codex は TOML、OMP と OpenCode は各自の tool 名を持つ frontmatter Markdown へ build 時に変換する。Antigravity は `definitionMode = "unsupported"` と宣言し、設定漏れと未対応を区別する。変換は各 client module が所有する。

配備の形は `definitionMode` が決める。`native` と `rendered` は home 配下の規定 path へ symlink する。Codex は `declared` を使い、home へは配らず、`config.toml` の `[agents.<role>]` から Nix store の実体を `config_file` で指す。Codex が role file を `O_NOFOLLOW` で開き、symlink を拒否するためである。

local skill は [`agents/shared/skills/`](../../agents/shared/skills) から自動検出する。local skill と [`flake.nix`](../../flake.nix) に固定した plugin skill は、どちらも Nix store source として全 client へ配備する。本文の変更にも rebuild が必要である。local と plugin、plugin 同士の同名 skill は評価時に拒否する。

複数の owner repository から Skill と runtime package を取り込む target 構成は、[Repository 所有 Skill の composition](repository-skills.md)に記録する。これは未実装であり、現行の `dotfiles.agents.shared.skills` と plugin 自動検出の説明を置き換えていない。

配備済み Skill と評価前の候補を分け、候補の責務境界と donor は [Skill portfolio](skills.md) に記録する。

## CLI ごとの差

| Client | Agent definitions | LSP | Telemetry | Agentmemory |
|---|---|---|---|---|
| Claude Code | native Markdown | plugin | managed settings | lifecycle hooks |
| Codex | rendered TOML | unsupported | unsupported | lifecycle hooks |
| OMP | rendered frontmatter Markdown | native config | unsupported | native hooks |
| OpenCode | rendered frontmatter Markdown | config | unsupported | capture plugin |
| Antigravity | unsupported | unsupported | unsupported | unsupported |

全 client が共通 rules、skills、単一 gateway の設定を持つ。Claude Code の user settings と Codex の user config は client が更新し得るため、Home Manager activation は配備先に通常 file、symlink、directory などの既存物がない場合だけ seed を書く。seed は runtime drift の対象にしない。OMP では共有対象の `AGENTS.md`、skills、agents、`mcp.json`、`lsp.json`、hooks だけを Home Manager が所有し、OMP が書き換える `config.yml` と認証 DB `agent.db` は client 所有の可変 file として残す。system または Home Manager が配備する managed file は artifact owner が observation を登録し、doctor が current source との不一致を検査する。OpenCode と Antigravity の gateway config は Home Manager が所有する。

## MCP target、front、gateway

[`flake.nix`](../../flake.nix) の `dotfiles.mcp.enabledProviders` は、この host が必要とする provider unit を固定する。各 [`mcp/NAME/module.nix`](../../mcp) は `dotfiles.mcp.targets` に provider ID、純 stdio executable、server lifecycle、port、外部通信の要否、backend unit、読み取り用 probe を宣言する。provider roster と target が公開する provider 集合は完全一致し、provider が target を持たない状態も未承認 provider の target も評価時に拒否する。target 名は gateway が tool 名へ付ける prefix であり、package 名とは別である。

[`mcp/module.nix`](../../mcp/module.nix) は `dotfiles.mcp.targets` から `dotfiles.mcp.fronts` を一度だけ導く。`service` lifecycle は `mcp-proxy` と一つの stdio server を front service の寿命で共有する。`session` lifecycle は一 target の agentgateway を HTTP adapter とし、downstream session ごとに stdio server を生成して `DELETE` または idle expiry で終了する。session front は listener 自身を loopback に bind し、管理 listener を持たない。backend を持つ target では `waitUnits` を front の `requires` と `after` の両方へ設定する。外部通信が不要な front は systemd の通信制限でも loopback に閉じる。

[`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) の `dotfiles.mcp.gateway` は単一 endpoint の ID、port、URL、service、runtime directory、YAML source、target 名を公開する。gateway は全 front へ loopback HTTP で接続し、front service を起動依存に持たず、子 process も作らない。各 AI CLI が知る接続先はこの URL だけである。session の idle policy は `dotfiles.mcp.sessionPolicy` が所有し、session front の TTL は gateway の TTL に grace を加えて先行 expiry を防ぐ。

target を持つかどうかは、agent が消費するかで決まる。agent が読み書きするものは target、人が browser で開くだけのものは endpoint に留める。SonarQube のように両方あるものは両方持つ。container application の endpoint は [`containers/sonarqube/module.nix`](../../containers/sonarqube/module.nix)、agent が使う target は [`mcp/sonarqube/module.nix`](../../mcp/sonarqube/module.nix) が宣言する。

browser を使う target は二つある。[`playwright`](../../mcp/playwright) は通常の操作、snapshot、screenshot、console、network の観測に使う。[`chrome-devtools`](../../mcp/chrome-devtools) はperformance trace、heap、Lighthouseなどの詳細観測に使う。両 target は `session` lifecycle を使い、tab、page、browser process を downstream session 間で共有しない。chromium package は `dotfiles.mcp.chromium` で共有し、二つの closure を持たない。

MCP target の実装は、host process だけで完結するものと常駐 backend を使うものに分かれる。現在の target は `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.mcp.targets --apply builtins.attrNames` で取得する。

session の生存は downstream が response body を保持しているかで決まる。pending の SSE stream は 15 秒ごとに comment frame を返し、body が生きている GET stream は idle TTL を超えても reap されない。idle は body の終了時刻から数え、明示 DELETE は即座に session を削除する。browser front は outer session より長い TTL を cleanup fallback として持つ。

## Docker backend

[`containers/module.nix`](../../containers/module.nix) は `dotfiles.containers` の型付き service contract、Docker daemon、`dotfiles-backends` network、OCI image の同期を所有する。[`container-backend.nix`](../../containers/impl/container-backend.nix) は container 宣言と systemd 依存を組み立て、必要な host port だけを `127.0.0.1` に publish する。front は host loopback の backend port に接続する。

application 固有の contract と container 宣言は各 application の [`containers`](../../containers) unit が所有する。対応する [`mcp`](../../mcp) unit には front package と target だけを置き、secret の値、path、owner、mode、template、OCI container、provisioning は宣言しない。front が owner の既存 secret file を直接読む場合に限り、MCP unit はその secret の `restartUnits` に front service を加える。SonarQube の front は container owner が公開する endpoint、admin password file、backend unit を型付き contract から読む。

全 container は暗黙 pull を無効にしている。upstream image は digest 固定の宣言と `dotfiles-sync-images`、Nix 生成 image は `imageFile` が取得を担当する。image があるかは docker が答えるので、同期の状態を別に記録しない。操作手順は [OCI images](../operations/oci-images.md)を参照する。

Docker build artifact GC は、dangling image と BuildKit cache だけを所有する。daemon の native policy は、image と共有しない cache のうち 60 日未使用のものを先に回収し、残りを含めて 30GB に保つ。全 cache は 100GB に保ち、各規則で 10GB を残す。`defaultKeepStorage` は回収しない下限であって上限ではないため使わない。6 時間ごとの persistent timer は dangling image を回収してから、internal image と frontend image を含む BuildKit cache を 100GB まで回収する。tagged image、container、volume は削除しない。GC service は Docker を soft dependency として参照し、Docker や各 backend から GC への起動依存は持たない。

## agentmemory

[`containers/agentmemory/module.nix`](../../containers/agentmemory/module.nix) は upstream package root、version、endpoint と agentmemory engine の Docker container を所有する。[`agents/agentmemory/module.nix`](../../agents/agentmemory/module.nix) はその型付き upstream contract から lifecycle hook package と OpenCode capture plugin を導き、agent 側へ配備する。保存先は host の `/var/lib/agentmemory/data` を container の `/data` へ mount した領域であり、Nix store には保存しない。[`mcp/memory/module.nix`](../../mcp/memory/module.nix) は engine の型付き endpoint と client version を読み、MCP front と memory target を配備する。

```text
Claude Code / Codex / OMP hooks ─┐
OpenCode capture plugin ─────────┼─► 127.0.0.1 の engine API ─► /var/lib/agentmemory/data
                                 │
AI CLI ─► gateway ─► memory MCP front ──────────────────┘

session start ─► recall と context 注入
session event ─► 観測、要約、reflect、consolidation
```

Claude Code と Codex は設定から、OMP は native TypeScript hook adapter から `/run/current-system/sw/bin/agentmemory-hook-*` を呼ぶ。OpenCode は Home Manager が配備した capture plugin を自動ロードする。Antigravity は gateway 経由の memory target を使えるが、自動 capture の設定はない。現在の差異は個別 CLI module と managed config が正本である。

agentmemory の LLM 処理は外部の OpenAI 互換 endpoint を使う。API key は SOPS template が runtime の環境ファイルへ展開し、Docker が container 環境へ渡す。session の prompt や code が外部 provider へ送られる境界を持つ。

## LSP と観測

language server の binary は `toolchain` が PATH へ置き、roster も同じ unit が持つ。roster から各 client の登録形式への写像は [`agents/impl/lsp.nix`](../../agents/impl/lsp.nix) が単独で持ち、各 client の module は生成した attrset を自分の配備形式へ包むだけにする。Claude Code は `settings.json` に LSP の設定 key を持たないので、plugin と marketplace を Nix store に生成して managed settings から指す。OMP は `lsp.json`、OpenCode は設定ファイルの `lsp` block へ配る。LSP を持たない CLI には配らない。

roster が宣言するのは、checkout の内容ではなく環境が提供する集合である。したがって「宣言した server は client と checkout に関係なく、対応する拡張子を開いた時点で有効になる」を不変条件とする。ところが登録の既定は client ごとに違う。Claude Code は有効条件の field を持たず拡張子だけで解決する。OMP は宣言した名前で上流 `defaults.json` の同名 server へ shallow merge するので、`rootMarkers` を宣言しないと Cargo.toml や package.json の有無で有効集合が変わる。OpenCode は同 id の built-in から `root` 解決を引き継ぐので、workspace root の位置が上流の marker 表で決まり、marker が見つからないときに諦める実装では起動もしない。

そこで写像は継承を制御する。OMP へは `rootMarkers` に cwd 自体を渡して有効条件を自分で決め、名前は実装が同一の server だけ上流に合わせる。csharp の roslyn-ls と typescript の tsgo は上流の同名 server とは別実装なので自前の名前を与え、OmniSharp と tsserver 向けの設定を受け取らない。OpenCode は config に `root` を書けないため、id に所有者を前置して built-in から切り離す。前置しないと同じ roster の中で由来が分かれる。`bash`、`csharp`、`rust`、`typescript` は上流 built-in と同名で root を借り、`java`、`nix`、`python` は同名の built-in が無いので project directory を使っていた。

同じ拡張子を二つの server が宣言すると、先に登録された片方だけが動き、もう片方は黙って起動しない。roster と各 client の登録の一致、client ごとの id 規則、OMP の有効条件、拡張子の衝突は `lsp-registration` が検査する。

telemetry collector は OTLP を loopback で受け、生の record を残す。集計しないのは、どの操作で token を使ったかを後から追うためである。CLI は endpoint を `dotfiles.telemetry` から取るので、port を変えても CLI 側の宣言は変わらない。

配備後の調査は [Doctor](../operations/doctor.md)、構成変更の適用は [Rebuild](../operations/rebuild.md)に従う。
