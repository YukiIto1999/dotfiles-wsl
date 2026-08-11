# Agent client の更新

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

現在の checkout が宣言する client binary を更新する。

```sh
cd ~/dotfiles-wsl
nix run .#dotfiles-install-agents
```

current generation では `dotfiles-agent-autoupdate.timer` が同じ installer を日次実行する。起動予定と直近の結果は systemd から確認する。

```sh
systemctl status dotfiles-agent-autoupdate.timer
systemctl status dotfiles-agent-autoupdate.service
```

## 宣言と release の確認

installer が受け取る manifest は次の command で表示できる。credential は含まない。

```sh
nix run .#dotfiles-install-agents -- --print-manifest | jq .
```

Codex と OpenCode の管理済み release は client ごとの directory にある。`current` と visible binary は相対 symlink であり、release 名は取得した archive の SHA-256 digest から決まる。

```sh
find ~/.local/share/dotfiles/agents -maxdepth 3 -mindepth 2 -print
readlink ~/.local/share/dotfiles/agents/codex/current
readlink ~/.local/bin/codex
readlink ~/.local/share/dotfiles/agents/opencode/current
readlink ~/.local/bin/opencode
```

GitHub release の取得、digest 照合、archive 検査、required path 検査、version probe のどれかが失敗した場合は、新しい `current` へ切り替えない。publish 中の通常の失敗でも旧 `current` へ rollback する。所有または identity を確認できない object は削除せず、エラーとして残す。Claude Code と Antigravity の配置と rollback は upstream installer の責務である。

`SIGKILL`、電源断、WSL の強制停止では自動 rollback を保証しない。中断後は installer を再実行し、同じ checkout の contract を使う `nix run .#dotfiles-doctor` で検査する。再実行が失敗するか `agent/<client>` check が `fail` になった場合は、残った object を手で削除しない。check ID から client を特定し、上記の client directory、`current`、visible binary を調査する。

client contract や timer を変えた後の system generation への反映は通常の [Rebuild](rebuild.md)に従う。配備方式と信頼境界は [AI tooling](../architecture/ai-tooling.md#client-binary-の更新)と[セキュリティ境界](../architecture/security.md#agent-client-の供給経路)を参照する。
