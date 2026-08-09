# Doctor

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

`dotfiles-doctor` は、宣言した常駐 service と MCP の実用状態に加え、WSL の資源枯渇を読み取り専用で検査する。service が active か、gateway が MCP の initialize を返すか、宣言した target すべての tool が `tools/list` に現れるかを順に確認する。unit が active でも session を張れない場合や、upstream の fanout で tool が消える場合があるため、unit の状態だけでは成功にしない。

資源検査の対象は次のとおり。

- zram の algorithm と swap priority、swap 総量
- root filesystem と Windows D ドライブの空き
- journald の使用量
- Nix GC、fstrim、BuildKit GC、agent cache GC、worktree reaper の timer
- service と container の再起動回数
- `~/.cache/dotfiles-wsl/builds`、`~/.cache/dotfiles-wsl/sessions`、`~/.local/state/dotfiles-wsl/agent-resources` の管理下領域

project や home 全体への再帰 scan、cleanup、service 再起動、trim は行わない。

```sh
dotfiles-doctor          # 人が読む形
dotfiles-doctor --json   # 機械が読む形
```

warning だけなら exit 0、failure があれば exit 1 になる。人向け出力と JSON 出力は、どちらも check ごとの `pass`、`warn`、`fail` を返す。Windows 側の値や外部 command の未信頼出力は failure message へ反映しない。

```sh
systemctl --failed
journalctl -u UNIT -n 30
```

宣言と実装の整合は `nix flake check` が build 前に見る。doctor は実際に動いているかだけを見る。
