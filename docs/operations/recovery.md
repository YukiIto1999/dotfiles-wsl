# データの復旧

**読み手:** 別PCへ環境を移す人と、設定だけでなく履歴や永続dataを復旧する運用者。

Gitと`flake.lock`は設定の正本であり、CLIの認証、Atuinの履歴、OMPのsession、Hindsightのvolume、host key、Windows設定は含まない。
`dotfiles-rebuild --rollback`もこれらのdataを戻さない。
新規構築は[セットアップ](getting-started.md)、generationの復旧は[Rebuild](rebuild.md)、Windows資源は[Doctor](doctor.md#windows-の準備)を使う。

## 復旧対象

| 対象 | 所在と扱い | 成功条件 |
|---|---|---|
| 設定 | commit済みcheckoutと`flake.lock` | 対象hostの評価と適用が成功する |
| Agent CLI | upstream installerまたは管理release | 採用clientの版を確認し、実際に起動する |
| 認証 | user-ownedのclient状態、SOPSのruntime配備物 | 新しいhostで再認証し、採用clientの接続を確認する |
| Atuin | `~/.local/share/atuin/`と`~/.config/atuin/`。history DB、record DB、keyを含む | 既知の履歴を検索でき、同期が無効である |
| OMP | `~/.omp/agent/`の可変DB、config、sessions | 引き継ぐsessionを開け、新しいsessionも起動できる |
| project memory | Dockerの`hindsight-data` named volume | 既知の保存済み文書を同じproject scopeで取得できる |
| host key | `/var/lib/sops-nix/key.txt` | 所有者とmodeを満たし、当該hostの暗号文を復号できる |
| Windows | distribution登録名、`.wslconfig`、Windows上のrepositoryと追加drive | 登録名と資源を確認し、URL、file、directoryの相互操作を実行できる |

home、DB、volumeには秘密情報や個人情報が含まれるため、backupは暗号化された外部媒体へ保存する。
Git、`work/`、公開artifactへdata本体や復号鍵を置かない。
別PCで新しいhostとして併用する場合は、既存host keyを共有せず、新しい鍵を登録してCLIを再認証する。
同一hostの災害復旧と、別identityを持つ新規hostの構築を混ぜない。

## Distributionのbackup

稼働中のDBをfileごとにコピーせず、書込みを止めたdistribution全体をWSLの標準exportで保存する。
全sessionの作業とserviceの書込みが終わったことを確認してから、Windows PowerShellで実行する。
ここでの停止は同じdistributionの全processを止めるため、検証中のsessionから実行しない。

```powershell
wsl.exe --list --verbose
wsl.exe --terminate 'NixOS'
wsl.exe --export 'NixOS' 'E:\EncryptedBackup\NixOS.tar'
Get-FileHash -Algorithm SHA256 'E:\EncryptedBackup\NixOS.tar'
```

`NixOS`はhostの`dotfiles.workstation.wsl.distroName`へ、保存先は暗号化された外部媒体の実際のpathへ置き換える。
export前に書込みを止められなかったbackupは、DBの整合性を保証したbackupとして扱わない。
Windowsの`.wslconfig`と追加drive上のdataはexportに含まれないため、別に保存する。

## 別名でのrestore

元のdistributionを削除せず、新しい名前と空の保存directoryへimportする。
復旧確認前に`wsl.exe --unregister`を使わない。

```powershell
wsl.exe --import 'NixOS-Restore' 'D:\WSL\NixOS-Restore' 'E:\EncryptedBackup\NixOS.tar' --version 2
wsl.exe --distribution 'NixOS-Restore' --user nixos
```

restoreしたdistributionを同一hostの復旧環境として使う場合も、元の環境と同時に外部送信するtimerやAgent sessionを動かさない。
継続運用する登録名はhost profileへ反映し、通常の検証、commit、rebuildを通す。
別hostとして使う場合は、持ち込んだhost identityと認証をそのまま再利用せず、[SOPS登録](sops-enrollment.md)と再認証を行う。

restoreの成功は、importの終了statusだけでは判定しない。
復旧対象の既知のdataを読み、採用clientを起動し、`dotfiles-doctor`のfailureを解消し、Windows相互操作を実際に確認する。
復旧環境で書込みと再起動を行った後も同じdataが読めることを確認してから、backupを復旧可能と記録する。
検証をしていないbackupと、空のDBで起動できただけの環境は、restore済みとして扱わない。
