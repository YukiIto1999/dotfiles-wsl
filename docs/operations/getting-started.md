# セットアップ

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

新規の NixOS-WSL ホストを、この repository の checkout から構築する。中断のない通常系は、host key の enrollment、bootstrap、WSL 再起動、containerを選ぶhostだけOCI imageの同期、rebuild、doctor の順に進める。

## 前提

- NixOS-WSL を用意し、構築する host 構成の `dotfiles.workstation.username` と同じユーザーでログインする。宣言は checkout の root で `nix eval --raw .#nixosConfigurations.<host-id>.config.dotfiles.workstation.username` を実行して確かめる。登録済みの host はどれも既定値の `nixos` を使い、これは NixOS-WSL の初期ユーザーと同じである。別のユーザー名を宣言する host は、そのユーザーが存在しないため初回構築できない。[bootstrap script](../../workstation/activation/rebuild/impl/bootstrap.sh) は、`sudo` の実行元ユーザーがこの宣言と一致することを検査する。
- リポジトリを host 構成の `dotfiles.workstation.dotfilesDir` が指す場所へ clone し、作業ツリーを変更のない状態にする。場所は checkout の root で `nix eval --raw .#nixosConfigurations.<host-id>.config.dotfiles.workstation.dotfilesDir` を実行して確かめる。実行した checkout がこの場所と異なれば、bootstrap は宣言された path を表示して止まる。
- recovery key を読み取り専用の外部媒体から一時的に参照できるようにする。host key はこの host で生成し、別ホストの鍵をコピーしない。
- `profiles/hosts/<host-id>.nix` が存在する host ID を使う。現在の登録値は `nixos` と `tcs-a295` である。ID は63文字以内の小文字英数字またはハイフンで構成し、英数字で始めて終える。

再現対象は tracked source と `flake.lock` から生成する system と Home Manager の設定である。AI CLI の login session、Hindsightのnamed volumeにあるproject-memory data、host keyはホスト固有であり、別ホストから複製しない。AI CLI 本体は bootstrap 時点の upstream 版を取得するため、`flake.lock` の再現対象には含まれない。

## Host key

以降の command は checkout の root で実行する。この host で鍵を生成し、root だけが読める場所へ置く。

```bash
age-keygen -o /tmp/host.key
sudo install -m 0400 -o root -g root /tmp/host.key /var/lib/sops-nix/key.txt
```

生成した公開鍵を `secrets/sops/assets/.sops.yaml` の `keys` に host anchor として追加し、`creation_rules` から参照する。併用する host の anchor は残したまま追加する。続けて recovery key で再暗号化する。

```bash
SOPS_AGE_KEY_FILE=/media/offline/recovery-key.txt \
  sops --config secrets/sops/assets/.sops.yaml updatekeys secrets/sops/assets/secrets.json
SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops --config secrets/sops/assets/.sops.yaml decrypt secrets/sops/assets/secrets.json > /dev/null
```

最後の復号が成功してから先へ進む。**確かめる前に旧 recipient を外すと全 secret を失う。**手順の詳細は [SOPS の鍵](sops-enrollment.md)にある。

変更対象を確認する。

```bash
git diff --check
git diff -- secrets/sops/assets
git status --short
```

`git status --short` に表示される変更は `secrets/sops/assets/.sops.yaml` と `secrets/sops/assets/secrets.json` の二つだけにする。bootstrap 前は Git identity が未配備なので、この時点では commit しない。鍵の交換が済んだら recovery key をホストから取り外す。

## Bootstrap

host 構成が宣言する主ユーザーから `sudo` を介し、構築対象の host ID を明示して実行する。

```bash
HOST_ID=tcs-a295
sudo bash workstation/activation/rebuild/impl/bootstrap.sh --host "$HOST_ID"
```

[bootstrap script](../../workstation/activation/rebuild/impl/bootstrap.sh) は次の順序で初回 generation を用意する。

| 順序 | 処理 |
|---|---|
| 1 | root として実行され、`sudo` の実行元ユーザーが分かることを確認する |
| 2 | root の Git `safe.directory` に checkout を登録する |
| 3 | flake、lock、暗号化済み secrets、host key の存在と host key の owner、mode を検査する |
| 4 | 選択した host 構成の `dotfiles.workstation.username` と `dotfiles.workstation.dotfilesDir` が、`sudo` の実行元ユーザーと実行した checkout に一致することを確認する |
| 5 | flake build から見えない未追跡ファイルがないことを確認する |
| 6 | host key で `secrets/sops/assets/secrets.json` を復号できることを確認する |
| 7 | 選択した host 構成の AI CLI を upstream から `~/.local/bin` へ配置する |
| 8 | 選択した host 構成と flake が固定した `nixos-rebuild` で boot generation を作る |
| 9 | `/etc/nixos` を checkout への symlink にする |

## 初回同期

bootstrap が完了したら、PowerShell から NixOS-WSL を停止して起動する。

```powershell
wsl -t NixOS
wsl -d NixOS
```

再ログイン後は、bootstrapが表示したhost別の継続手順を通常ユーザーで実行する。container Capabilityを選ぶhostでは、upstream OCI imageを同期してから同じcheckoutを適用する。以下の短いcommandは、active host configurationが配備したものを使う。

checkoutから対象hostを明示して実行する場合は、次のpathを使う。

```bash
nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages -- --status
nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages
```
active host configurationが配備したcommandは、次のように短い名前で実行する。

```bash
dotfiles-sync-images
dotfiles-rebuild
```

container Capabilityを一つも選ばないhostでは同期command自体を配備しない。bootstrapの表示どおり、rebuildだけを実行する。

```bash
dotfiles-rebuild
```

初回boot generationのcontainer unitは、Docker cacheにupstream imageがないため失敗し得る。containerを選ぶhostでは、`dotfiles-sync-images`の後に`dotfiles-rebuild`を実行すると、同期済みimageを使ってserviceが収束する。rebuildが別のWSL再起動を指示した場合は、表示された手順を完了してから検証へ進む。

## 検証

system generation、service、managed file、OCI image、AI CLI、MCP の実状態を検査する。

```bash
dotfiles-doctor
git diff --check
git diff -- secrets/sops/assets
git status --short
```

doctor が成功し、`git status --short` に暗号化済みファイル二つ以外の変更がないことを確認する。sops-nix が配備した Git identity を使い、`secrets/sops/assets/.sops.yaml` と `secrets/sops/assets/secrets.json` を同じ commit に記録する。

## 別 host への再現

別ホストでも clone から検証まで同じ順序を使い、ホストごとに登録済みの host ID と新しい host key を使う。既存ホストの `/var/lib/sops-nix/key.txt` や `~/.config/sops/age/keys.txt` はコピーしない。

Windows drive の一覧は対応する [`profiles/hosts/`](../../profiles/hosts) の profile に置く。memory と swap の既定値は実装側の共通方針で、差が必要な host だけ同じ profile から `dotfiles.workstation.swap` または `dotfiles.workstation.windowsMemoryCommit` を上書きする。

全host共通のCapabilityは[`profiles/workstation.nix`](../../profiles/workstation.nix)、containerを含むhost固有のCapabilityは同じhost profileの`dotfiles.capabilities.enabled`で選ぶ。`code-quality`、`project-memory`、`web-content`、`web-discovery`を外すと、対応するcontainerだけでなくMCP target、credential、health observation、client integrationも配備されない。container backendを一つも選ばないhostではDocker自体を配備しない。

新しい enrollment を始める前に、直前のホストで生じた暗号化済み差分を commit し、その repository を利用する全ホストへ同期する。bootstrap 前に差分を退避する必要がある場合は、平文を保存せず、外部媒体へ Git patch を作る。

```bash
git diff --binary -- secrets/sops/assets \
  > /media/offline/desktop-nixos-enrollment.patch
```
