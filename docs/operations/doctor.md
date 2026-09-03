# Doctor

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

`dotfiles-doctor` は current generation が宣言した runtime observation を読み取り専用で実行する。検査対象の唯一の inventory は `dotfiles.observations` であり、各 owner が自分の service、timer、path、資源、protocol を登録する。doctor は owner 名、systemd description、unit 名の部分一致から対象を推測しない。

```sh
dotfiles-doctor
dotfiles-doctor --json
```

## 検査契約

[`observations/module.nix`](../../observations/module.nix) は次の 17 種類の observation kind を閉じた union として受け付ける。

| 対象 | kind |
|---|---|
| roster と path | `roster`、`path-match`、`command-version`、`release-tree`、`deployed-path`、`path-metadata`、`managed-roots` |
| systemd と再起動 | `systemd-service`、`systemd-timer`、`restart-counter` |
| 容量と committed memory | `filesystem-threshold`、`numeric-command-threshold`、`swap-policy`、`journal-size` |
| container と protocol | `container-image`、`http-health`、`normalized-protocol` |

[`commands/doctor/module.nix`](../../commands/doctor/module.nix) は registry 全体を key 順の JSON に投影し、[`commands/doctor/impl/doctor.sh`](../../commands/doctor/impl/doctor.sh) が各 observation を同じ runner で処理する。個別 probe は宣言した timeout、許可した変数だけの環境、専用の一時 directory で動く。stdout は上限を設けた JSON fragment だけを受理し、stderr は捨てる。不正、過大、timeout、非ゼロ終了は owner が宣言した固定 failure message に置き換える。

MCP gateway の initialize、tools/list、target probe は `mcp` owner の `normalized-protocol` observer が行う。doctor 自体には MCP の状態機械を持たせない。

agent の管理下領域は次の四つを一度に集計する。

- `~/.cache/dotfiles-wsl/builds`
- `~/.cache/dotfiles-wsl/shared`
- `~/.cache/dotfiles-wsl/sessions`
- `~/.local/state/dotfiles-wsl/agent-resources`

home や project 全体は再帰 scan しない。doctor は cleanup、GC、service 再起動、trim を実行しない。Linux root、Windows C、D、E drive、Windows committed memory、swap topology を観測対象とする。Windows の各 probe は同じ有界な数値 contract を使い、drive は空き率、committed memory は使用率を返す。

## 結果

`--json` の top-level は `checks`、`warnings`、`failures`、`resources` である。`checks` は `id` と `pass`、`warn`、`fail` の status、warning と failure は `id` と固定 message を持つ。`resources` は observation が公開を許した集計値だけを key-value object にまとめる。

secret の内容、PAT、外部 command の raw stdout と stderr は結果へ出さない。MCP の observer も normalized outcome と許可した resource だけを返す。

終了 status は次のとおり。

| status | 条件 |
|---|---|
| `0` | 全 check が `pass` または `warn` |
| `1` | 一件以上が `fail` |
| `2` | 引数が不正 |

failure の unit を調べる場合は、結果の ID に対応する owner 宣言を確認してから journal を読む。

```sh
systemctl --failed
journalctl -u UNIT -n 30
```

宣言と実装の整合は `nix flake check` が build 前に検査する。doctor は activation 後の実状態だけを観測する。
