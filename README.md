# dotfiles-wsl

NixOS on WSL2 のホスト設定、AI coding CLI の共通ルール、MCP、SOPS 管理の secrets を `~/dotfiles-wsl` から再現するための flake。

この repository は **repo root を flake root** とする。`/etc/nixos` は `~/dotfiles-wsl` への symlink にする。

## Layout

| path | 役割 |
|---|---|
| `flake.nix` | flake inputs、user 名、gateway URL、GitHub account list、plugin source |
| `etc/nixos/configuration.nix` | NixOS、WSL、Docker、SOPS、MCP container、systemd service |
| `etc/nixos/home.nix` | Home Manager、CLI 設定、agents / skills 配備 |
| `home/nixos/` | `/home/nixos` 配下へ置く設定 template |
| `share/` | 共通ルール、agents、local skills |
| `templates/` | SOPS template と generated config template |
| `services/` | stdio MCP を HTTP MCP 化する自前 OCI image |
| `scripts/bootstrap.sh` | 初回 setup |
| `scripts/install-ai-clis.sh` | CLI 本体の upstream install / update |
| `scripts/doctor.sh` | 適用後の実用状態検証 |
| `scripts/cleanup-local.sh` | 正常化後の不要物整理 |
| `scripts/fetch-mcp-info.sh` | MCP tarball hash / image digest 更新補助 |

## 前提

| 項目 | 置き場所 |
|---|---|
| リポジトリ | `~/dotfiles-wsl` |
| age 秘密鍵 | `/var/lib/sops-nix/key.txt` |
| SOPS ファイル | `~/dotfiles-wsl/secrets/secrets.yaml` |

`secrets/secrets.yaml` は `/var/lib/sops-nix/key.txt` で復号できる必要がある。

## 初回セットアップ

```bash
cd ~/dotfiles-wsl
sudo bash scripts/bootstrap.sh
```

bootstrap は次だけを行う。

| 順序 | 内容 |
|---|---|
| preflight | repo root flake、lock、secrets、age key の存在確認 |
| verify_tracked_flake_files | flake build から全ファイルが見えることを確認 |
| sync_submodules | submodule を初期化し、`.gitmodules` の `sparse-checkout` を適用 |
| verify_secrets | `nix shell "git+file://${HOME}/dotfiles-wsl?submodules=1#sops" -c sops -d secrets/secrets.yaml` |
| install_ai_clis | `scripts/install-ai-clis.sh` を通常ユーザーで実行し、CLI 本体を upstream から `~/.local/bin` に配置 |
| install_boot_generation | `nixos-rebuild boot --flake "git+file://${HOME}/dotfiles-wsl?submodules=1#nixos" -L` |
| link_nixos | `/etc/nixos` を `~/dotfiles-wsl` に向ける |

bootstrap は CLI の設定ディレクトリを直接変更しない。CLI 本体だけを `~/.local/bin` に配置し、設定ファイルとの衝突は Home Manager の `backupFileExtension = "hm-back"` に任せる。

bootstrap 完了後、PowerShell から WSL を再起動する。

```powershell
wsl -t NixOS
wsl -d NixOS
```

再起動後に検証する。

```bash
~/dotfiles-wsl/scripts/doctor.sh
```

## 再ビルド

WSL では systemd restart により VS Code Remote WSL セッションが切れるため、通常更新も boot generation として入れる。

```bash
sudo nixos-rebuild boot --flake "git+file:///home/nixos/dotfiles-wsl?submodules=1#nixos" -L
```

その後 PowerShell から再起動し、`doctor.sh` を実行する。

## Cleanup

正常化後に不要物を整理する。既定は dry-run。

```bash
~/dotfiles-wsl/scripts/cleanup-local.sh
```

削除する。

```bash
~/dotfiles-wsl/scripts/cleanup-local.sh --delete
```

system backup と VS Code server runtime も整理する場合。

```bash
~/dotfiles-wsl/scripts/cleanup-local.sh --delete --system --vscode-server
```

`--vscode-server` は `~/.vscode-server` を削除する。VS Code Remote WSL は次回接続時に server runtime を再インストールする。

## AI coding CLI

`dotfiles-wsl` は CLI 本体を Nix から入れない。nixpkgs は最新に追従しないため、本体は upstream の公式配布を使う。

| command | 配置 | 更新元 |
|---|---|---|
| `claude` | `~/.local/bin/claude` | Anthropic 公式 installer |
| `codex` | `~/.local/bin/codex` | OpenAI GitHub Release |
| `opencode` | `~/.local/bin/opencode` | Anomaly GitHub Release |
| `agy` | `~/.local/bin/agy` | Google 公式 installer |

bootstrap は `scripts/install-ai-clis.sh` を通常ユーザーで実行し、最新の upstream binary を配置する。Nix が管理するのはインストールに必要な一時ツール、OS 設定、MCP、Home Manager 管理ファイルだけ。

設定ファイル、agents、skills は Home Manager が配置する。

| path | 内容 |
|---|---|
| `~/.claude/settings.json` | prompt cache、UI 設定 |
| `~/.claude/CLAUDE.md` | `share/AGENTS.md` 由来の共通ルール |
| `~/.claude/agents/<name>.md` | `share/agents/*.md` 由来 |
| `~/.claude/skills/<name>` | local / plugin skill への symlink |
| `~/.codex/config.toml` | model、gateway MCP |
| `~/.codex/AGENTS.md` | `share/AGENTS.md` 由来の共通ルール |
| `~/.codex/agents/<name>.toml` | frontmatter TOML + developer_instructions |
| `~/.codex/skills/<name>` | local / plugin skill への symlink |
| `~/.config/opencode/opencode.json` | gateway MCP |
| `~/.config/opencode/AGENTS.md` | `share/AGENTS.md` 由来の共通ルール |
| `~/.config/opencode/agents/<name>.md` | `share/agents/*.md` 由来 |
| `~/.config/opencode/skills/<name>` | local / plugin skill への symlink |
| `~/.gemini/antigravity-cli/mcp_config.json` | gateway MCP |
| `~/.gemini/AGENTS.md` | `share/AGENTS.md` 由来の共通ルール |
| `~/.gemini/agents/<name>.md` | `share/agents/*.md` 由来 |
| `~/.gemini/antigravity-cli/skills/<name>` | local / plugin skill への symlink |

`doctor.sh` は CLI が Nix 管理の `/nix/store`、`/run/current-system`、`/etc/profiles` から解決される場合に失敗する。

## MCP

全 CLI は gateway だけを見る。

```text
Claude Code / Codex CLI / OpenCode / Antigravity CLI
        |
        v
http://localhost:8765/mcp
        |
        v
agentgateway
```

`gatewayPort` は `flake.nix` の `gatewayPort` で宣言する。各 CLI は upstream API に従って同じ URL を見る。

Docker、MCP containers、agentgateway は NixOS configuration により一括管理する。

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

`identity/work/*` は `workIdentity != null` のときだけ必要。

## Change targets

| やりたいこと | 触る場所 |
|---|---|
| GitHub account を増減 | `flake.nix` の `accounts`、`secrets/secrets.yaml` の `accounts/<account>` |
| work identity を変える | `flake.nix` の `workIdentity`、必要なら `identity/work/*` |
| default git identity を変える | `secrets/secrets.yaml` の `identity/default/*` |
| local skill を足す | `share/skills/<name>/SKILL.md` |
| subagent を足す | `share/agents/<name>.md` |
| 共通ルールを変える | `share/AGENTS.md` |
| CLI 設定を変える | `home/nixos/` 配下の各 CLI テンプレート |
| gateway target を変える | `etc/agentgateway/config.yaml` と `etc/nixos/configuration.nix` |
| secret template を変える | `templates/*` と `etc/nixos/configuration.nix` |

変更後は以下を実行する。

```bash
sudo nixos-rebuild boot --flake "git+file:///home/nixos/dotfiles-wsl?submodules=1#nixos" -L
```

PowerShell から WSL を再起動し、`scripts/doctor.sh` を実行する。

## License

[MIT](LICENSE)
