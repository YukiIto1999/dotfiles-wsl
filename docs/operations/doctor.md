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
| roster と path | `roster`、`path-match`、`command-version`、`release-tree`、`deployed-path`、`path-metadata` |
| systemd、cgroup と再起動 | `systemd-service`、`systemd-socket`、`systemd-timer`、`restart-counter`、`process-slice` |
| 容量と committed memory | `filesystem-threshold`、`numeric-command-threshold`、`numeric-command-threshold-set`、`swap-policy`、`journal-size` |
| container と protocol | `container-image`、`http-health`、`normalized-protocol` |

[`health/module.nix`](../../health/module.nix) は registry 全体を key 順の JSON に投影し、[`health/impl/doctor.sh`](../../health/impl/doctor.sh) が各 observation を同じ runner で処理する。
個別 probe は宣言した timeout、許可した変数だけの環境、専用の一時 directory で動く。
stdout は上限を設けた JSON fragment だけを受理し、stderr は捨てる。
不正、過大、非ゼロ終了の結果は、owner が宣言した固定 failure message の `fail` に置き換える。
宣言した timeout までに終わらない probe は、`observation did not finish within <秒数>s` という message の `warn` にする。
期限切れは観測が終わらなかったことだけを示し、対象の故障を示さないためである。
memory と I/O が逼迫すると、正常な service の probe も、swap と page cache から追い出された process と binary の読み戻しだけで期限を超える。
これを `fail` にすると恒常的な fail が出力を読み飛ばす習慣を作り、[ADR 0013](../adr/0013-drop-the-codex-mcp-session-capability.md) が避けた状態に戻る。
`warn` は終了 status を変えないが、期限切れの check は結果に残る。

観測する対象の数が実行時に決まる資源には `numeric-command-threshold-set` を使う。owner の command は 1 行に 1 つ `<名前> <百分率>` を返し、doctor は名前ごとに閾値を当てて `<checkId>/<名前>` の check を作る。1 行でも読めなければ、どの値も使わずに observation 全体を固定 failure message で失敗させる。

MCP gateway の initialize、tools/list、target probe は Platform MCP の `normalized-protocol` observer が行う。doctor 自体には MCP の状態機械を持たせない。

observer は要求ごとに期限を持ち、期限内に終わらない要求を、その期限の秒数を示す `observation did not finish within <秒数>s` の `warn` にする。
target の tools/call の期限は target の probe が宣言した timeout、それ以外の要求の期限は全 target の timeout の最大値である。
target の tools/call の故障は `fail` のまま、次の message で種類を示す。

| message | 条件 |
|---|---|
| `MCP tools/call returned an MCP error` | JSON-RPC の error、`isError` が true の tool 結果、HTTP 400 以上の status |
| `MCP tools/call response violates the MCP contract` | 一つの JSON-RPC 応答として読めないか、result と error の形が MCP の規約に合わない応答 |
| `MCP tools/call connection to the gateway failed` | 接続の拒否、切断、空の応答など、HTTP の応答を得られない失敗 |

`process-slice` は、owner が宣言した directory の下の実行 file で動く process が、宣言した systemd slice の cgroup に入っているかを見る。
probe は `/proc/<PID>/exe` の link 先を directory の前方一致で照合するので、更新後も旧 release で動き続ける process と、削除済みの実行 file で動く process も対象になる。
process の `environ` は、swap に出た page の読み戻しを誘発するので読まない。
slice の外の process が一つでもあれば `fail` にし、slice の内と外の process 数を resource に出す。

doctor は directory の容量を再帰的に数えない。
巨大な build cache の `du` は負荷の下で期限内に終わらず、それ自体が I/O を足すためである。
Linux root の空きは `resource/root-filesystem` の使用率で見る。

doctor は cleanup、GC、service 再起動、trim を実行しない。
Linux root、WSL の root VHD、Windows drive、Windows committed memory、swap topology を観測対象とする。
Windows drive の観測対象は宣言せず、WSL が drvfs として mount した drive の root を実行時に見つけて、drive ごとの空き率を `resource/windows-drives/<drive letter>` に出す。
未 mount の drive の空きと VHDX の配置先は、この結果だけでは分からない。
Windows committed memory は host が選んだ PowerShell から使用率を得る。
root VHD は root disk の容量を `resource/wsl-vhd/capacity`、PowerShell で読んだ Windows 側の `.wslconfig` の VHD 設定を `resource/wsl-vhd/wslconfig` に出す。

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

## host の選択

別 PC では [`profiles/hosts/`](../../profiles/hosts) の対象 host で、Windows の登録名と資源条件を選ぶ。
option の正本は WSL、storage、Nix、stability の各 owner module であり、現在 PC の DNS、G:、VM 資源、VHD、Nix 並列度と容量 reserve は `profiles/hosts/nixos.nix` に限って宣言する。
主 user の既定 `nixos` と WSL の登録名の既定 `NixOS` は独立している。

| option | 既定と用途 |
|---|---|
| `dotfiles.workstation.wsl.distroName` | `NixOS`、Windows に登録した distribution 名 |
| `wsl.nameservers` | `[]`、WSL の生成 DNS を使用、必要な host だけ resolver を明示 |
| `wsl.extraDrives` | `[]`、必要な host だけ `["G:"]` 等を `/mnt/g` 等へ非阻害 automount |
| `wsl.powershellCommand` | `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`、Windows command の入口 |
| `wsl.windowsConfig.memoryGiB`、`processors`、`swapGiB` | `null`、WSL 既定を維持、指定値だけ Windows 準備用 template に出力 |
| `storage.vhd.sizeGiB`、`sparse` | `256` GiB と `false`、作成予定の VHD と doctor の期待値 |
| `storage.journal.maximumGiB` | `1` GiB、journald の容量上限 |
| `nix.maxJobs`、`cores` | 各 `1`、同時 build 数と各 build の CPU 数 |
| `nix.minimumFreeGiB`、`targetFreeGiB` | `4` GiB と `8` GiB、store 自動 GC の開始値と目標値 |
| `swap.zramMemoryPercent`、`minimumTotalGiB` | RAM の `25`% と合計 `1` GiB、zram と swap の最低条件 |

表の `wsl`、`storage`、`nix`、`swap` はすべて `dotfiles.workstation` の配下である。
Nix の目標 reserve は VHD 容量より小さくし、VM processor 数を宣言する場合は `maxJobs * cores` がその数を超えないようにする。
Windows の RAM、CPU、VHDX 配置先の空き、pagefile と disk swap を先に確認し、VM 上限と VHD 上限を host に合わせる。
VHD 上限は Windows drive の空き容量を予約せず、sparse を明示しても host drive 枯渇の保護が不要になるわけではない。
zram と Agent の資源保護は維持し、Windows の template 値を稼働中 VM の実 RAM とみなさない。

## Windows の準備

初回 system closure の適用前には、checkout で対象 host の template を表示する。

```sh
HOST=nixos
nix eval --raw ".#nixosConfigurations.$HOST.config.dotfiles.workstation.wsl.windowsConfigTemplate"
```

適用済み host では `dotfiles-wsl-config` が同じ本文を表示し、`--help` で用途を確認できる。
どちらの入口も Windows の file を上書きせず、WSL の停止、VHD の resize、再作成を実行しない。
Windows の `%UserProfile%\.wslconfig` を backup してから表示した key を既存の対応 section へ統合し、重複 key を除く。
無関係な既存 key と他の distribution の必要条件を消さず、`memory`、`processors`、`swap` が WSL2 VM 全体に作用することを確認する。
`null` の key は template に出ないので、WSL 自動既定へ戻す場合は既存 file の該当 key も手動で除く。
VHD 設定は次に作る VHD の準備であり、既存 VHD の容量や稼働中 VM の資源上限を変更したことにはならない。
VM 資源設定の反映に停止が必要な場合は全 distribution の作業を記録し、利用者が停止を選べる保守時に行う。
反映後は Windows で `wsl --list --verbose` の登録名、Linux で実 RAM、CPU 数、swap を確認し、doctor の容量と資源結果を合わせて判断する。

```sh
free -h
nproc --all
swapon --show
dotfiles-doctor
```

## Windows 相互操作

`wslview [--] URL_OR_PATH` は一つの URL、Windows 絶対 path、既存 Linux file または directory を Windows の既定 application で開く。
Linux path は `realpath` で絶対 path にし、`wslpath -w` で drive path または distribution の UNC path に変換する。
Windows の drive path と UNC path、URI scheme のある URL はそのまま渡す。
`file:` URL は Windows 側で解釈する URL であり、Linux の `file:///home/...` を自動変換する入口ではないので、Linux file は path で指定する。
空白、日本語、引用符、`&`、`$`、`;` を含む target は一つの引数に引用し、本文は UTF-8 の Base64 として Windows に渡す。
target を PowerShell の code や application の追加引数として評価しない。
先頭が `-` の path は `--` の後に置き、application 引数は受け付けない。

| 終了 status | 意味 |
|---|---|
| `0` | Windows が起動要求を受理、または `--help` が成功 |
| `2` | target 不足、複数 target、空文字、改行を含む target、不明 option |
| `1` | Linux path が存在しない、path 変換失敗、Windows の起動処理が例外 |
| その他の非ゼロ | PowerShell の起動失敗や Windows process の終了 status |

`0` だけでは browser の読込み、file の表示、Windows 側の権限を保証しない。
対話的な実機 smoke は、対象 launcher の絶対 path を指定して明示的に実行する。

```sh
bash workstation/wsl/impl/smoke-windows.sh "$(command -v wslview)" --open
```

smoke は example.com の URL、特殊文字を含む一時 directory とローカル HTML を開き、引数不正の status も確認する。
browser の URL、Explorer の directory 名、HTML の表示文字を目で確認して記録し、Enter で一時 file を除く。
clipboard、Windows 設定、既存 VHD、WSL session の状態は変更しない。
回帰 check `wslview-behavior` は URL、Windows path、Linux path、特殊文字、余分な引数、変換失敗、Windows 失敗 status を検査し、`wsl-host-policy-contract` は別 PC の DNS、drive 不在、登録名、VM 資源、VHD、Nix 設定と template を検査する。

Explorer は `wslview DIRECTORY`、path 変換は既存の `/bin/wslpath` で足りるため、専用 wrapper は増やさない。
clipboard を使う場合も Windows の既存 `clip.exe` と PowerShell の `Get-Clipboard` を明示的に呼べるため、汎用 Windows 操作 framework は設けない。
clipboard の読書きは内容を変更し得るので smoke から外し、利用する時に日本語と改行の往復を別途確認する。

## WSL の VHD が宣言と異なる場合

root VHD の容量上限と sparse 設定の期待値は、`dotfiles.workstation.storage.vhd` から Windows 準備用 template と doctor へ導く。
Windows 側の `%UserProfile%\.wslconfig` の `defaultVhdSize` と `sparseVhd` は新規 VHD の作成条件であり、既存の root VHD の sparse 属性までは doctor が検査していない。
既定の non-sparse 方針を維持し、Windows drive の空き率と容量差の fail を確認する。

`resource/wsl-vhd/wslconfig` が fail の場合は、Windows 準備入口の本文を確認して、`.wslconfig` の `[wsl2]` の `defaultVhdSize` と `[experimental]` の `sparseVhd` を host の宣言値に合わせる。
WSL は同じ key の二つ目以降を無視するため、重複した行も消す。
この設定確認は既存の VHD と稼働中の session を変えないので、WSL を再起動せずに doctor を再実行できる。

`resource/wsl-vhd/capacity` が fail の場合は、root VHD が宣言と異なる設定で作られたか、後から resize されている。root disk の容量を byte 単位で確かめる。

```sh
lsblk -bdno SIZE "$(findmnt -no SOURCE /)"
```

容量差を template の書換えだけで直そうとせず、既存 VHD の維持、保守時の resize、新しい登録名での復元のどれを選ぶかを先に決める。
移行する場合は全 session を終了できる保守時に Windows 側で export し、元の登録を残したまま別名へ import する。
次の `Distro` は host option の `distroName` に合わせ、`Backup` と `InstallDir` は十分な空きのある実在する配置先を選ぶ。

```powershell
$Distro = 'NixOS'
$Backup = 'E:\Backups\NixOS.tar'
$RecoveryName = 'NixOS-Recovery'
$InstallDir = 'E:\WSL\NixOS-Recovery'
wsl --export $Distro $Backup
if ($LASTEXITCODE -ne 0) { throw 'export failed; original distribution must be preserved' }
wsl --import $RecoveryName $InstallDir $Backup --version 2
if ($LASTEXITCODE -ne 0) { throw 'import failed; original distribution must be preserved' }
```

export と import の終了 status だけで backup と復旧の成功を断定せず、別名で起動して file、秘密鍵の権限、必要な data、root 容量、doctor の結果を確認する。
元の VHD を削除する `wsl --unregister` はこの手順に含めず、Windows 設定から破壊的な再作成を自動実行しない。

## WSLが重い場合

Orcaの描画停止だけでOMP sessionの停止を断定しない。既存terminalが応答する場合はterminalを閉じず、`wsl --shutdown`も実行しない。これは全distributionと既存sessionを終了し、実行中状態とprompt cacheを失わせる。

WSL内部では定期的な`drop_caches`を実行しない。clean page cacheの一括破棄は、複数のAgentが必要ファイルを同時に再読込みしてVHDのI/Oキューを急増させるためである。メモリ安定化はAgent runtimeの`agents.slice`の上限、zram、kernelの既定のwatermarkとcompactionで行う。

新規 session だけが停止し、kernel journal に `Relay` の `Waiting for abnormally long accept` や `SessionLeader` の `accept4 failed 110` がある場合も、Relay を定期走査して kill しない。
VHDX を置いた Windows drive の空き、WSL 内の空き、root の読み書き可否をそれぞれ確認し、稼働中 session を記録したうえで障害を切り分ける。
WSL 内の空きだけでは VHDX を収容する Windows 側の空きは分からない。

```sh
df -h /
findmnt -no SOURCE,OPTIONS /
```

`resource/wsl-memory/*` は、新しい WSL session と interop の接続が作れなくなる前兆と結果を、VM の中だけで観測する。
どれも `/proc` と kernel log を読むだけで、Windows の interop を通らない。

| check | 観測 | 判定 |
|---|---|---|
| `vmbus-ring-failures` | この boot の kernel log にある `vmbus_alloc_ring` の確保失敗の件数 | 1 件以上で `fail` |
| `stuck-relays` | 親を失って PID 1 の子として 300 秒以上残る `Relay` の数 | 1 個以上で `fail` |
| `high-order-pages` | 空きが boost を含む min と Normal への lowmem reserve を超える zone にある、order 7 以上と order 9 以上の空き block の数 | order 7 以上が 0 で `fail`、order 9 以上が 0 で `warn` |
| `memory-pressure`、`io-pressure` | PSI の `full` の 60 秒平均 | 10% 以上で `warn`、40% 以上で `fail` |

新しい session は VMBus の ring に 512 KiB、つまり order 7 の連続領域を確保し、確保に失敗すると `Relay` が accept を待ったまま残る。
`vmbus-ring-failures` と `stuck-relays` は、WSL を再起動するまで `fail` のまま残る。
`high-order-pages` の order 9 は空いた pageblock 一つ分に当たり、これが無くなると高次の確保は他の用途の block を分割するしかない。
PSI の `full` は、実行可能な全 task が memory または I/O を待って止まっていた時間の割合である。
40% を超えた時間帯には、正常な service に対する doctor の probe と MCP の呼出しも期限を超えた。
kernel log の走査が 20 秒で終わらない場合は、`vmbus-ring-failures` を期限を示す `warn` にし、他の check の結果は残す。

sessionを復旧する場合は、利用者が明示したsession名と文面だけを使う。spinner、経過時間、最終出力から作業中か入力待ちかを推測して一括入力しない。

宣言と実装の整合は `nix flake check` が build 前に検査する。doctor は activation 後の実状態だけを観測する。
