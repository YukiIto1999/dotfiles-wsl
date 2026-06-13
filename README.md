# dotfiles-wsl

WSL2 上の NixOS ホスト設定、AI コーディング CLI の共通ルール、MCP、SOPS 管理の secrets を `~/dotfiles-wsl` から再現する flake。

リポジトリルートを flake のルートとする。`/etc/nixos` は `~/dotfiles-wsl` への symlink にする。

このリポジトリは、Claude Code / Codex / OpenCode / Antigravity に同じルール、agents / skills、MCP gateway 設定を配備する。共通定義は `share/` に置き、各 CLI の形式へ変換する。

## 構成

| パス | 役割 |
|---|---|
| `flake.nix` | inputs(nixpkgs / nixos-wsl / home-manager / sops-nix / plugin sources)と nixosSystem の定義、checks |
| `modules/` | NixOS module。`options.nix`(`my.*` 型付き設定)、`wsl` / `nix` / `base` / `secrets` / `mcp` / `home` |
| `home/` | Home Manager module。`default` / `cli`(agents・skills を全 CLI へ配備)/ `git`。`home/nixos/` は配備元の生 config |
| `pkgs/` | MCP server の build 定義。stdio 実行 package(共通 `mk-mcp-server` helper 使用)、agentgateway の binary、Chromium 起動設定、agentmemory のバックエンド用 Docker image |
| `share/` | `AGENTS.md`(共通ルール)、`agents/`(subagent)、`skills/`(local skill) |
| `templates/` | SOPS / 生成 config の template(`gh-user` / `searxng-settings` / `agentmemory`) |
| `secrets/` | `secrets.yaml`(SOPS + age)と `.sops.yaml` |
| `scripts/` | `bootstrap` / `doctor` / `install-ai-clis` / `cleanup-local` / `fetch-mcp-info` |

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
| install_ai_clis | CLI 本体を upstream から `~/.local/bin` へ配置 |
| install_boot_generation | `nixos-rebuild boot --flake "git+file://${HOME}/dotfiles-wsl#nixos" -L` |
| link_nixos | `/etc/nixos` を `~/dotfiles-wsl` に向ける |

完了後、PowerShell から WSL を再起動して検証する。

```powershell
wsl -t NixOS
wsl -d NixOS
```

```bash
~/dotfiles-wsl/scripts/doctor.sh
```

## 再ビルド

WSL では systemd の再起動で VS Code Remote セッションが切れるため、通常更新は次回起動時に使う generation として反映する。

```bash
sudo nixos-rebuild boot --flake "git+file:///home/nixos/dotfiles-wsl#nixos" -L
```

その後 PowerShell から再起動し、`doctor.sh` を実行する。flake input の更新は `nix flake update`。

## AI コーディング CLI

CLI 本体は Nix でインストールしない。更新頻度が高く常に最新が望ましいため、各 CLI の公式配布を `~/.local/bin` に置く。dotfiles は設定・agents・skills を管理する。

| command | 配置 | 更新元 |
|---|---|---|
| `claude` | `~/.local/bin/claude` | Anthropic 公式 installer |
| `codex` | `~/.local/bin/codex` | OpenAI GitHub Release |
| `opencode` | `~/.local/bin/opencode` | Anomaly GitHub Release |
| `agy` | `~/.local/bin/agy` | Google 公式 installer |

`share/AGENTS.md`(共通ルール)、`share/agents/*.md`(subagent)、plugin・local の skills を、`home/cli.nix` が各 CLI のネイティブ形式へ配備する。agent は Claude=md そのまま / Codex=TOML 化 / OpenCode=tools 変換。Antigravity は plugin ベースで static agent 機構を持たないため agent は配備せず、rules + skills + gateway だけを受け取る。

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
 context7 / probe-mcp / memory / crawl4ai /
 searxng-mcp / playwright / github-mcp-<account>
        |  loopback (常駐プロセスを使う target のみ)
        v
 docker network mcp-backends:
 searxng + valkey / crawl4ai / agentmemory engine
```

- gateway は `127.0.0.1:8765` のみで待ち受ける。`my.gatewayPort` で宣言する。
- MCP server はすべて stdio で gateway から起動する。HTTP target、OCI image、mcp-proxy は使わない。
- github は account ごとに wrapper を spawn し、`/run/secrets` から PAT を読んで exec する。`docker inspect` への露出は無い。
- 常駐プロセス(searxng / valkey / crawl4ai / agentmemory engine)だけ `mcp-backends` network の Docker で動かす。stdio server は `127.0.0.1` に公開した port 経由で接続する。
- Playwright MCP は host の Chromium を headless で起動する。専用 daemon と Docker image は使わない。GitHub MCP は Docker network へ置かない。

## Secrets と identity

| key | 用途 |
|---|---|
| `identity/default/name` | default git user.name |
| `identity/default/email` | default git user.email |
| `identity/work/name` | work identity の git user.name |
| `identity/work/email` | work identity の git user.email |
| `accounts/<account>/username` | `gh` と GitHub MCP の username |
| `accounts/<account>/token` | `gh` と GitHub MCP の PAT |
| `searxng/secret_key` | SearXNG の `server.secret_key` |

`identity/work/*` は `my.workIdentity != null` のときだけ必要。

## 変更箇所

| やりたいこと | 触る場所 |
|---|---|
| GitHub account を増減 | `flake.nix` の `my.accounts`、`secrets/secrets.yaml` の `accounts/<account>` |
| work identity を変える | `flake.nix` の `my.workIdentity`、必要なら `identity/work/*` |
| default git identity を変える | `secrets/secrets.yaml` の `identity/default/*` |
| local skill を足す | `share/skills/<name>/SKILL.md` |
| subagent を足す | `share/agents/<name>.md` |
| 共通ルールを変える | `share/AGENTS.md` |
| CLI 設定を変える | `home/nixos/` 配下の各 CLI テンプレート |
| MCP server を増減 | `pkgs/<name>` を `mk-mcp-server` で足し、`modules/mcp/servers.nix` の target に追加。backing daemon は `modules/mcp/backends.nix` |

変更後は rebuild する。

```bash
sudo nixos-rebuild boot --flake "git+file:///home/nixos/dotfiles-wsl#nixos" -L
```

PowerShell から WSL を再起動し、`scripts/doctor.sh` を実行する。

## セキュリティ

- gateway は loopback 限定で認証は持たない。同一ユーザーのプロセスは gateway 経由で GitHub の書き込み操作などを実行できる。被害を絞るため、PAT は fine-grained + 最小スコープにする。
- age 鍵は `/var/lib/sops-nix/key.txt`(root `0400`)だけに置く。`~/.config/sops/age/keys.txt` の複製は全 secret を平文で読める状態にするため置かない。編集は `sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops secrets/secrets.yaml`。`doctor.sh` が複製を検出して警告する。
- 鍵紛失に備え、`.sops.yaml` にオフライン保管の recovery recipient を 1 つ追加して `sops updatekeys` しておく。

## CI

`.github/workflows/check.yml` が push / PR で `nix flake check` を実行する。checks は system toplevel の build、`deadnix`、`shellcheck`。

## License

[MIT](LICENSE)
