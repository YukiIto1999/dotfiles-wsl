# Doctor

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

`dotfiles-doctor` は current generation が宣言した runtime observation を読み取り専用で実行する。検査対象の唯一の inventory は `dotfiles.health.observations` であり、各 owner が自分の service、timer、path、資源、protocol を登録する。doctor は owner 名、systemd description、unit 名の部分一致から対象を推測しない。

```sh
dotfiles-doctor
dotfiles-doctor --json
```

## 検査契約

[`health/module.nix`](../../health/module.nix) は次の 19 種類の observation kind を閉じた union として受け付ける。

| 対象 | kind |
|---|---|
| roster と path | `roster`、`path-match`、`command-version`、`release-tree`、`deployed-path`、`path-metadata`、`managed-roots` |
| systemd と再起動 | `systemd-service`、`systemd-socket`、`systemd-timer`、`restart-counter` |
| 容量と committed memory | `filesystem-threshold`、`numeric-command-threshold`、`numeric-command-threshold-set`、`swap-policy`、`journal-size` |
| container と protocol | `container-image`、`http-health`、`normalized-protocol` |

[`health/module.nix`](../../health/module.nix) は registry 全体を key 順の JSON に投影し、[`health/impl/doctor.sh`](../../health/impl/doctor.sh) が各 observation を同じ runner で処理する。個別 probe は宣言した timeout、許可した変数だけの環境、専用の一時 directory で動く。stdout は上限を設けた JSON fragment だけを受理し、stderr は捨てる。不正、過大、timeout、非ゼロ終了は owner が宣言した固定 failure message に置き換える。

観測する対象の数が実行時に決まる資源には `numeric-command-threshold-set` を使う。owner の command は 1 行に 1 つ `<名前> <百分率>` を返し、doctor は名前ごとに閾値を当てて `<checkId>/<名前>` の check を作る。1 行でも読めなければ、どの値も使わずに observation 全体を固定 failure message で失敗させる。

MCP gateway の initialize、tools/list、target probe は Platform MCP の `normalized-protocol` observer が行う。doctor 自体には MCP の状態機械を持たせない。

agent の管理下領域は次の四つを一度に集計する。

- `~/.cache/dotfiles-wsl/builds`
- `~/.cache/dotfiles-wsl/shared`
- `~/.cache/dotfiles-wsl/sessions`
- `~/.local/state/dotfiles-wsl/agent-resources`

home や project 全体は再帰 scan しない。doctor は cleanup、GC、service 再起動、trim を実行しない。Linux root、Windows drive、Windows committed memory、swap topology を観測対象とする。Windows drive は宣言せず、WSL が drvfs として mount した drive の root を実行時に見つけて、drive ごとの空き率を `resource/windows-drives/<drive letter>` に出す。Windows committed memory は PowerShell から使用率を得る。

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

## WSLが重い場合

Orcaの描画停止だけでOMP sessionの停止を断定しない。既存terminalが応答する場合はterminalを閉じず、`wsl --shutdown`も実行しない。これは全distributionと既存sessionを終了し、実行中状態とprompt cacheを失わせる。

WSL内部では定期的な`drop_caches`を実行しない。clean page cacheの一括破棄は、複数のAgentが必要ファイルを同時に再読込みしてVHDのI/Oキューを急増させるためである。メモリ安定化はkernel watermark、proactive compaction、zramで行う。

新規sessionだけが停止し、kernel journalに`Relay`の`Waiting for abnormally long accept`や`SessionLeader`の`accept4 failed 110`がある場合も、Relayを定期走査してkillしない。Dドライブの空き、WSL内の空き、ルートの読み書き可否をそれぞれ確認し、稼働中sessionを記録したうえで障害を切り分ける。WSL内の空きだけではVHDXを収容するWindows側の空きは分からない。

```sh
df -h / /mnt/d
findmnt -no SOURCE,OPTIONS /
```

sessionを復旧する場合は、利用者が明示したsession名と文面だけを使う。spinner、経過時間、最終出力から作業中か入力待ちかを推測して一括入力しない。

宣言と実装の整合は `nix flake check` が build 前に検査する。doctor は activation 後の実状態だけを観測する。
