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

`secrets/secrets.yaml` は `/var/lib/sops-nix/key.txt` で復号できる必要がある。新規マシンでは既存の age 鍵を `install -m600` で置くか `age-keygen -o /var/lib/sops-nix/key.txt` で作り、その公開鍵を `.sops.yaml` に登録して `sops updatekeys` する。

## 初回セットアップ

```bash
cd ~/dotfiles-wsl
sudo bash scripts/bootstrap.sh
```

bootstrap は次を実行する。

| 順序 | 内容 |
|---|---|
| register_safe_directories | root がリポジトリを扱えるよう `safe.directory` を登録(冪等) |
| preflight | flake / lock / secrets / age key の存在確認 |
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

WSL では systemd の再起動で VS Code Remote セッションが切れるため、通常更新は次回起動時に使う generation として反映する。通常更新は `dotfiles-rebuild` を使う。

```bash
dotfiles-rebuild
```

その後 PowerShell から再起動し、`dotfiles-doctor` を実行する。flake input の更新は `nix flake update`。

## 検証

検証は `dotfiles-doctor` で行う。CLI 本体が upstream 配布のままか、rules / skills / agents / gateway ファイルが配備されているか、systemd unit が起動しているかを確認する。さらに gateway へ MCP `initialize` → `tools/list` を実行し、`my.mcp.targets` の全 target の応答を検査する。

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

PowerShell から WSL を再起動し、`dotfiles-doctor` を実行する。

## セキュリティ

- gateway は loopback 限定で認証は持たない。同一ユーザーのプロセスは gateway 経由で GitHub の書き込み操作などを実行できる。被害を絞るため、PAT は fine-grained + 最小スコープにする。
- age 鍵は `/var/lib/sops-nix/key.txt`(root `0400`)だけに置く。`~/.config/sops/age/keys.txt` の複製は全 secret を平文で読める状態にするため置かない。編集は `sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops secrets/secrets.yaml`。`dotfiles-doctor` が複製を検出して警告する。
- `.sops.yaml` の recipient は現在 primary age key 1 つのみで、鍵紛失時の復旧経路が無い。復旧用の recipient を 1 つ追加し、`sops updatekeys` で反映する。

## CI

`.github/workflows/check.yml` が push / PR で `nix flake check` を実行する。checks は `nixos-toplevel`(system closure の build)、`deadnix`、`shellcheck`、`statix`、`nixfmt`(`--check`)、`config-syntax`(配備する JSON / TOML / YAML の構文検査、`@var@` 埋め込み箇所は dummy 値を埋めた derivation で検査)。

## License

[MIT](LICENSE)
