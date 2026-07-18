# dotfiles-wsl

WSL2 上の NixOS ホスト設定、AI コーディング CLI の共通ルール、MCP、SOPS 管理の secrets を `~/dotfiles-wsl` から再現する flake。

リポジトリルートを flake のルートとする。`/etc/nixos` は `~/dotfiles-wsl` への symlink にする。

このリポジトリは、Claude Code / Codex / OpenCode / Antigravity に同じルール、agents / skills、MCP gateway 設定を配備する。共通定義は `share/` に置き、各 CLI の形式へ変換する。

## 構成

| パス | 役割 |
|---|---|
| `flake.nix` | inputs(nixpkgs / nixos-wsl / home-manager / sops-nix / plugin sources)、nixosSystem の定義、`packages`(`dotfiles-install-clis` など)、`checks` |
| `modules/` | NixOS module 一式。`default.nix`(imports)、`options.nix`(`my.*` 型)、`wsl.nix` / `nix.nix` / `fonts.nix` / `secrets.nix`(git identity)、`accounts/`(GitHub account ごとの secrets と `gh` hosts 生成)、`mcp/`(gateway・docker network・`servers/<name>.nix`)、`clis/`(`my.clis` の CLI 一覧と CLI ごとの config、`share/` の配備)、`user/`(base user・git)、`commands.nix` + `commands/`(`dotfiles-*` 運用コマンドの生成元) |
| `pkgs/` | MCP server の build 定義(共通 `mk-mcp-server.nix` / `mk-npm-mcp.nix` helper 使用)、`agentgateway`、`agentmemory` の MCP server とバックエンド用 Docker image |
| `share/` | `AGENTS.md`(共通ルール)、`agents/`(subagent)、`skills/`(local skill) |
| `scripts/` | `bootstrap.sh`(初回セットアップ)、`pin-hash.sh`(pin 更新補助) |
| `secrets/` | `secrets.yaml`(SOPS + age)、`.sops.yaml` |
| `docs/adr/` | 構造に影響する決定の記録 |

## 前提

| 項目 | 置き場所 |
|---|---|
| リポジトリ | `~/dotfiles-wsl` |
| age 秘密鍵 | `/var/lib/sops-nix/key.txt`(root 専用、`0400`) |
| SOPS ファイル | `~/dotfiles-wsl/secrets/secrets.yaml` |

`/var/lib/sops-nix/key.txt` はホスト固有鍵とし、別ホストへ複製しない。通常の rebuild は既存鍵を読むだけで、鍵の生成や recipient の変更は行わない。

### age 鍵の enrollment

新規ホストは bootstrap の前に enrollment する。復旧鍵はオフラインで保管し、enrollment と復旧の間だけマウントする。

既存構成を移行するときは、最初に recovery identity を読み取り専用の外部媒体へ保管する。その identity の公開 recipient が `secrets/.sops.yaml` の `recovery` と一致し、現在の暗号文を復号できることを確認してから次へ進む。

1. 新規ホストで host key を生成する。

   ```bash
   age_keygen="$(nix build --no-link --print-out-paths .#age)/bin/age-keygen"
   sudo install -d -o root -g root -m 0700 /var/lib/sops-nix
   sudo "$age_keygen" -o /var/lib/sops-nix/key.txt
   sudo chmod 0400 /var/lib/sops-nix/key.txt
   sudo "$age_keygen" -y /var/lib/sops-nix/key.txt
   ```

2. 既存 recipient を削除せず、オフライン復旧鍵の公開 recipient と、直前に表示した新しい host recipient を `secrets/.sops.yaml` の同じ age key group に追加する。
3. 復旧鍵を一時的に指定し、`SOPS_AGE_KEY_FILE=/path/to/recovery-key nix shell .#sops -c sops --config secrets/.sops.yaml updatekeys secrets/secrets.yaml` を実行する。
4. host key と recovery key を一つずつ指定し、どちらでも復号できることを確認する。

   ```bash
   sops_bin="$(nix build --no-link --print-out-paths .#sops)/bin/sops"
   sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
     "$sops_bin" --decrypt secrets/secrets.yaml >/dev/null
   SOPS_AGE_KEY_FILE=/path/to/recovery-key \
     "$sops_bin" --decrypt secrets/secrets.yaml >/dev/null
   ```

5. 復旧鍵をホストから取り外してから bootstrap を実行する。

現在の暗号文には `secrets/.sops.yaml` の `recovery` recipient 1 つだけが登録され、その秘密鍵が runtime key と home 側に複製されている。二つ目の host recipient を登録し、両鍵の復号を確認してから旧 runtime key と home 複製を除く作業は、コード変更とは別の runtime migration として行う。

### 別ホストで再現する手順

再現対象は tracked source と `flake.lock` から生成する system / Home Manager 設定である。age の host key、AI CLI が保持する login session、agentmemory のデータはホスト固有なので複製しない。AI CLI 本体も bootstrap 時点の latest を取得する外部状態であり、`flake.lock` から同じ版を再現しない。

1. NixOS-WSL を用意し、このリポジトリを `~/dotfiles-wsl` へ clone する。
2. 新しい host key を生成し、公開 recipient だけを enrollment 済みの既存ホストへ渡す。既存ホストがない場合は、新規ホストへ一時的に recovery key を接続する。
3. 前節の手順で host recipient を追加し、`secrets/secrets.yaml` を再暗号化する。
4. 更新した2ファイルを一時転送し、新規ホストの host identity と offline recovery identity の両方で復号する。既存ホストで再暗号化した場合も、commit 前に新規ホストへ暗号文だけを渡して host identity を検証する。
5. recovery key をホストから外す。
6. `secrets/.sops.yaml` と `secrets/secrets.yaml` を同じ commit に記録し、利用する全ホストへ同期する。
7. `sudo bash scripts/bootstrap.sh` を実行する。
8. 初回の boot generation を読むため WSL を一度停止・起動し、`dotfiles-doctor` を実行する。

2台目以降も同じ手順を使う。既存ホストの `/var/lib/sops-nix/key.txt` や `~/.config/sops/age/keys.txt` をコピーして済ませない。

## 初回セットアップ

```bash
cd ~/dotfiles-wsl
sudo bash scripts/bootstrap.sh
```

bootstrap は次を実行する。

| 順序 | 内容 |
|---|---|
| register_safe_directories | root がリポジトリを扱えるよう `safe.directory` を登録(冪等) |
| preflight | flake / lock / secrets の存在と、enrollment 済み age key の owner / mode を確認 |
| verify_tracked_flake_files | untracked file が flake build から見えないため、無いことを確認 |
| verify_secrets | `nix shell .#sops -c sops -d secrets/secrets.yaml` で復号確認 |
| install_ai_clis | `nix run .#dotfiles-install-clis` で CLI 本体を upstream から `~/.local/bin` へ配置 |
| install_boot_generation | `nixos-rebuild boot --flake "git+file://${HOME}/dotfiles-wsl#nixos" -L` |
| link_nixos | `/etc/nixos` を `~/dotfiles-wsl` に向ける |

完了後、PowerShell から WSL を再起動して検証する。

```powershell
wsl -t NixOS
wsl -d NixOS
```

```bash
dotfiles-doctor
```

## 再ビルド

通常更新は `dotfiles-rebuild` を使う。先に適用内容だけを確認する場合は `--plan` を付ける。

```bash
dotfiles-rebuild --plan
dotfiles-rebuild
```

current generation の command を更新する前でも、checkout から同じ処理を実行できる。

```bash
nix run .#dotfiles-rebuild -- --plan
nix run .#dotfiles-rebuild
```

rebuild は untracked file を拒否した後、作業ツリーを Nix store へ一度だけ archive する。同じ immutable
snapshot に対して flake check と candidate build を実行し、`nvd` で current system との差分を表示する。
`--plan` はここで終了するため system profile と runtime は変えない。ただし、archive と build により
Nix store と cache は更新される。

apply では build 済み candidate の store path だけを `nixos-rebuild --store-path --no-reexec --sudo` へ渡す。
checkout の評価と build は一般ユーザー、system profile の更新と activation だけは root で実行する。
変更内容に応じた処理は次のとおり。

| effect | apply | WSL 操作 |
|---|---|---|
| `switch` | live switch 後に candidate の doctor を実行 | 不要 |
| `switch-restart` | live switch | 停止と起動を 1 回、その後 doctor |
| `boot-restart` | boot generation へ登録 | 停止と起動を 1 回、その後 doctor |
| `boot-two-stage` | boot generation へ登録 | root 起動を挟んで 2 回停止、その後 doctor |

`wsl.conf` と activation interface が同時に変わる場合と `wsl.defaultUser` の変更だけが二段階になる。
PowerShell で実行する正確な command は rebuild の終了時に表示する。flake input の更新は build と分け、
明示的に `nix flake update` を実行してから rebuild する。

## 検証

`nix flake check` と `dotfiles-doctor` は検査対象が異なるため、どちらも必要になる。flake check は評価した source から system closure と設定を生成できることを apply 前に検査する。doctor は apply 後の current generation が宣言した期待値と、system profile、systemd、SOPS host key、home 配下の CLI、MCP gateway の実状態が一致することを検査する。

doctor の期待値は current generation の `/run/current-system/etc/dotfiles/doctor.json` に収録する。mutable な checkout や `share/AGENTS.md` の表は inventory として読まない。次をすべて満たした場合だけ status 0 になる。

- system profile と実行中の doctor が current generation を指す
- WSL cold-start state が `switch` で、追加の停止・起動を必要としない
- 必須 unit の `LoadState` が `loaded`、`ActiveState` が `active`
- `/var/lib/sops-nix` が root `0700`、host key が root `0400` になっている。host/recovery key の移行中は home 側の旧 age key を警告し、移行完了後に policy を `reject` へ切り替えて残存を失敗にする
- health registry に登録した Claude、Codex、agentgateway の管理ファイルと、trusted project 用の `.codex/config.toml` が current generation の source と byte 単位で一致する
- 各 AI CLI が `~/.local/bin` の宣言パスから実行され、rules file が source と一致し、期待する各 `SKILL.md` と各 agent file が存在する
- OpenCode と Antigravity の gateway file が current generation の gateway URL を含む
- `wslview` が current generation の宣言した実体を指し、`cmd.exe /d /c exit 0` の probe が5秒以内に成功する
- MCP が `initialize`、`notifications/initialized`、全ページの `tools/list`、session `DELETE` を完走し、全 target が tool を公開する

doctor は secret の値、AI CLI の配布元・内容・版・login session、skill 本文と agent file の内容、checkout の clean 状態を検査しない。source と build の検査は `dotfiles-rebuild` と flake check が行う。enrollment では host identity と recovery identity、bootstrap では host identity による秘密値の復号を確認する。

## AI コーディング CLI

CLI 本体は Nix でインストールしない。更新頻度が高く常に最新が望ましいため、各 CLI の公式配布を `~/.local/bin` に置く。dotfiles は設定・agents・skills を管理する。

| command | 配置 | 更新元 |
|---|---|---|
| `claude` | `~/.local/bin/claude` | Anthropic 公式 installer |
| `codex` | `~/.local/bin/codex` | OpenAI GitHub Release |
| `opencode` | `~/.local/bin/opencode` | Anomaly GitHub Release |
| `agy` | `~/.local/bin/agy` | Google 公式 installer |

`modules/clis/` は `share/AGENTS.md`、`share/agents/*.md`、plugin / local skills を各 CLI の形式で配備する。Claude は agent の Markdown をそのまま使う。Codex は TOML、OpenCode は tools 用の形式へ変換する。Antigravity は静的な agent 機能を持たないため、rules / skills / gateway 設定だけを配備する。

MCP gateway の登録方法は CLI ごとに異なる。Claude は CLI が実行時に管理する `~/.claude.json` に `claude mcp add` で登録する。Codex は `/etc/codex/config.toml` に管理設定を置き、ユーザーが初期化する home 配下の config と分ける。OpenCode / Antigravity は home の MCP 設定ファイルへ置く。

Codex の `workspace-write` sandbox は作業ディレクトリに加え、この checkout の `.git` だけを書き込み可能にする。許可パスは Home Manager が `my.dotfilesDir/.codex/config.toml` へ生成し、Codex がこのリポジトリを trusted project として読む場合だけ有効になる。`/etc/codex/config.toml` には全 project 共通の gateway と hooks だけを置く。

## MCP

全 CLI は MCP gateway だけに接続する。gateway は systemd service として動作し、stdio server を子プロセスとして起動する。SearXNG など常駐が必要なプロセスだけ Docker で動かす。

```text
Claude Code / Codex / OpenCode / Antigravity
        |  http://localhost:8765/mcp  (loopback)
        v
   agentgateway (systemd)
        |  stdio (MCP server を起動)
        v
 context7 / probe / searxng / crawl4ai /
 memory / playwright / github-<account>
        |  loopback (常駐プロセスを使う target のみ)
        v
 docker network mcp-backends:
 searxng + valkey / crawl4ai / agentmemory engine
```

- gateway は `127.0.0.1:8765` のみで待ち受ける。`my.gatewayPort` で宣言する。
- MCP server はすべて stdio で gateway から起動する。HTTP target、OCI image、mcp-proxy は使わない。
- GitHub MCP は account ごとの wrapper が `/run/secrets` から PAT を読んで起動する。Docker コンテナではないため、`mcp-backends` network と `docker inspect` には露出しない。
- 常駐プロセス(searxng / valkey / crawl4ai / agentmemory engine)だけ `mcp-backends` network の Docker で動かす。stdio server は `127.0.0.1` に公開した port 経由で接続する。
- Playwright MCP は host の Chromium を headless で起動する。専用 daemon と Docker image は使わない。

## agentmemory

長期記憶。MCP target `memory` の tools に加え、engine 同梱の lifecycle hooks が全 CLI のセッションを自動観測する。

```
Claude Code (managed-settings.json) --\
Codex (/etc/codex/config.toml)      ---+-- agentmemory-hook-<event> --> REST 127.0.0.1:3111/agentmemory/observe
OpenCode (plugins/ 自動ロード)      --/
```

- hook 実体は `pkgs/agentmemory` が engine 同梱 script を `agentmemory-hook-<event>` として `/run/current-system/sw/bin` に公開する。宣言は `modules/mcp/servers/memory.nix` に集約。
- `session-start` は `AGENTMEMORY_INJECT_CONTEXT=true` で過去記憶をセッション冒頭に注入する。`stop` / `session-end` がセッション要約と登録を行う。
- OpenCode は `~/.config/opencode/plugins/agentmemory-capture.ts` の自動ロードで同等の観測を行う。
- LLM provider は OpenCode Go の OpenAI 互換 endpoint を使う。model は `minimax-m2.7`、embedding provider は `none`。
- 状態確認: `xh GET http://127.0.0.1:3111/agentmemory/health`、`memory_diagnose` / `memory_audit` tools。

## Secrets と identity

| key | 用途 |
|---|---|
| `identity/default/name` | default git user.name |
| `identity/default/email` | default git user.email |
| `identity/work/name` | work identity の git user.name |
| `identity/work/email` | work identity の git user.email |
| `accounts/<account>/username` | `gh` と GitHub MCP の username |
| `accounts/<account>/token` | `gh` と GitHub MCP の PAT |
| `opencode/go_api_key` | agentmemory が OpenCode Go を呼び出す API key |
| `searxng/secret_key` | SearXNG の `server.secret_key` |

`identity/work/*` は `my.workIdentity != null` のときだけ必要。

## 変更箇所

| やりたいこと | 触る場所 |
|---|---|
| GitHub account を増減 | `flake.nix` の `my.accounts`、`secrets/secrets.yaml` の `accounts/<account>/*` |
| work identity を変える | `flake.nix` の `my.workIdentity`、必要なら `secrets/secrets.yaml` の `identity/work/*` |
| default git identity を変える | `secrets/secrets.yaml` の `identity/default/*` |
| local skill を足す | `share/skills/<name>/SKILL.md` を置いて `git add` + `dotfiles-rebuild` |
| subagent を足す | `share/agents/<name>.md` を置いて `git add` + `dotfiles-rebuild` |
| 共通ルールを変える | `share/AGENTS.md` |
| CLI 固有の設定を変える | `modules/clis/<name>/` 配下のテンプレート |
| CLI を増減 | `modules/clis/<name>/` を足し、`modules/clis/default.nix` の imports に登録 |
| MCP server を増減 | `pkgs/<name>` を build 定義として足し、`modules/mcp/servers/<name>.nix` に target を追加、`modules/mcp/default.nix` の imports に登録 |
| secret を足す | 消費する module に `sops.secrets` を宣言し、`secrets/secrets.yaml` に値を足す |

変更後は rebuild する。

```bash
dotfiles-rebuild
```

`dotfiles-rebuild` が `switch` と判定した変更は WSL を止めず、live switch 後に doctor まで実行する。停止・起動が必要な場合だけ、終了時に表示される PowerShell command を実行する。

## セキュリティ

- gateway は loopback 限定で認証は持たない。同一ユーザーのプロセスは gateway 経由で GitHub の書き込み操作などを実行できる。被害を絞るため、PAT は fine-grained + 最小スコープにする。
- runtime migration 完了後は、ホスト固有の `/var/lib/sops-nix/key.txt`(directory は root `0700`、key は root `0400`)だけを置く。`~/.config/sops/age/keys.txt` に複製しない。通常の secret 編集は `sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops secrets/secrets.yaml` を使う。
- 現在の doctor manifest は移行中を示す `sops.homeKey.policy = "warn"` である。host key とオフライン復旧鍵の双方で復号を実測した後、`modules/secrets.nix` を `reject` へ変更し、旧 home key を削除する。
- オフライン復旧鍵は host key と同じ age key group に登録するが、通常運用するホストへ常置しない。recipient の追加と削除には `sops updatekeys` を使い、変更後は各 identity で個別に復号を確認する。

## CI

`.github/workflows/check.yml` が push / PR で `nix flake check` を実行する。checks は `nixos-toplevel`(system closure の build)、`doctor-runtime`(runtime failure matrix と MCP lifecycle)、`doctor-manifest-contract`(実配備 manifest と Home Manager / Codex / SOPS / WSL 宣言の一致)、`sops-policy`(鍵の自動生成禁止、owner / mode、recipient metadata)、`deadnix`、`shellcheck`、`statix`、`nixfmt`(`--check`)、`config-syntax`(配備する JSON / TOML / YAML の構文検査、`@var@` 埋め込み箇所は dummy 値を埋めた derivation で検査)。

## License

[MIT](LICENSE)
