# SOPSの鍵

**読み手:** secretを編集する運用者と、新しいホストや鍵を登録する運用者が、作業中に読む。

secretは`secrets/sops/assets/secrets.json`にageで暗号化して置き、`secrets/sops/assets/.sops.yaml`がrecipientを宣言する。
複数のホストが同じ暗号文を共有するため、併用するhost keyとrecovery keyをrecipientとして残す。

## 鍵の置き場

| 対象 | 置き場 | ownerとmode |
|---|---|---|
| host key directory | `/var/lib/sops-nix` | root:root、0700、symlink不可 |
| host key | `/var/lib/sops-nix/key.txt` | root:root、0400、symlink不可 |
| recovery key | ホスト外の外部媒体 | 運用者が保管し、登録時だけ読み取り専用で参照 |

host keyはsops-nixがactivation時に読む。
home、repository、一時directoryへ秘密鍵の複製を置かず、rootだけが読める鍵による操作はsudoを介する。
host keyはホストごとに生成し、別のホストへコピーしない。
全host keyを失った場合に備え、recovery keyをホスト外で保管する。

## secretの編集

checkoutのrootで、flakeが固定したSOPSを取得して編集する。

```sh
SOPS_PACKAGE=$(nix build --no-link --print-out-paths .#sops)
sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$SOPS_PACKAGE/bin/sops" --config secrets/sops/assets/.sops.yaml \
  secrets/sops/assets/secrets.json
git diff --check
git diff -- secrets/sops/assets/secrets.json
git add -- secrets/sops/assets/secrets.json
git commit -m 'chore: 暗号化secretsの更新'
dotfiles-rebuild
```

平文を別ファイル、shell history、Git patch、ログへ書かない。
通常の値変更では`updatekeys`を使わない。
`secrets.json`を編集しただけでは`/run/secrets`に反映されず、通常のrebuildにはcommitが必要である。

## 新しいhostの登録

対象hostのprofileは、鍵の登録前にcommitしたsourceとして用意する。
新しいホストのcheckoutのrootで、同じflakeのageとSOPSを取得する。

```sh
AGE_PACKAGE=$(nix --extra-experimental-features 'nix-command flakes' \
  build --no-link --print-out-paths .#age)
SOPS_PACKAGE=$(nix --extra-experimental-features 'nix-command flakes' \
  build --no-link --print-out-paths .#sops)
```

root専用のdirectory内で直接鍵を生成する。
既存の鍵やsymlinkがある場合は上書きせず止まるため、既存鍵の交換は下の復旧手順を使う。

```sh
sudo sh -c '
  set -eu
  test ! -L /var/lib/sops-nix
  install -d -m 0700 -o root -g root /var/lib/sops-nix
  test ! -e /var/lib/sops-nix/key.txt
  test ! -L /var/lib/sops-nix/key.txt
  umask 077
  "$1/bin/age-keygen" -o /var/lib/sops-nix/key.txt
  chmod 0400 /var/lib/sops-nix/key.txt
' sh "$AGE_PACKAGE"
sudo stat -c '%U:%G %a %n' /var/lib/sops-nix /var/lib/sops-nix/key.txt
sudo "$AGE_PACKAGE/bin/age-keygen" -y /var/lib/sops-nix/key.txt
```

`stat`の結果がdirectoryは`root:root 700`、鍵は`root:root 400`であることを確認する。
表示した公開鍵を`secrets/sops/assets/.sops.yaml`の`keys`に`host-<host-id>`anchorとして追加し、`creation_rules`から参照する。
秘密鍵の内容は表示しない。

読み取り専用の外部媒体からrecovery keyを参照し、暗号文のrecipientを更新する。
続いて新しいhost keyで実際に復号できることを確認する。

```sh
SOPS_AGE_KEY_FILE=/media/offline/recovery-key.txt \
  "$SOPS_PACKAGE/bin/sops" --config secrets/sops/assets/.sops.yaml \
  updatekeys secrets/sops/assets/secrets.json
sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$SOPS_PACKAGE/bin/sops" --config secrets/sops/assets/.sops.yaml \
  decrypt secrets/sops/assets/secrets.json > /dev/null
```

復号が成功するまで旧recipientを外さない。
併用するhostのrecipientは、登録後も残す。

```sh
git diff --check
git diff -- secrets/sops/assets/.sops.yaml secrets/sops/assets/secrets.json
git status --short
```

変更は上記の暗号化済みファイル二つだけにし、復号の確認後にrecovery keyの外部媒体を取り外す。
初回構築ではまだGit identityがないため、差分を保持して[bootstrap](getting-started.md#bootstrap)へ進み、boot generationへの再ログイン後に二つのファイルを同じcommitへ記録する。
そのcommitを終えてからimage同期と通常のrebuildへ進む。
既にGit identityを配備したホストで登録する場合は、確認後に二つのファイルを同じcommitへ記録し、併用するホストへsourceを同期する。
登録操作は自動commitやdirty拒否の例外を使わない。

## 鍵を失った場合

鍵を失った新しいホストでは、profileと暗号文をcloneし、上の手順で新しいhost keyを生成する。
recovery keyで新しい公開鍵をrecipientへ追加し、新しいhost keyによる復号を確認してからbootstrapする。
失われた旧host keyのrecipientを外す場合も、先に残す鍵による復号を確認する。
漏洩した鍵を退役させる場合は、recipientを外すだけで既に取得されたsecretの平文を無効化できないため、対応するcredentialも失効させて交換する。

recovery keyも失い、復号できるhost keyも残っていない場合は、暗号文からsecretを復元できない。
SOPS鍵の再登録はsystem generationやcontainerの永続dataのrestoreではないため、それぞれのbackupを別に扱う。

## 検査

`sops-policy`は、`keys`の宣言、`creation_rules`の参照、暗号文のrecipientの一致と重複の不在を検査する。
recovery anchorがちょうど一つ、`host-`anchorが一つ以上あり、登録済みhostのanchorが存在することも検査する。
`bootstrap-age-key`は鍵のownerとmode、symlink拒否、実際のage/SOPS復号、初回commitから通常のrebuildへ進む継続手順を検査する。
これらのfixtureは一時directoryを使い、実機の鍵、profile、service、WSLを変更しない。
