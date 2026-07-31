# セットアップ

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

新規の NixOS-WSL ホストを `~/dotfiles-wsl` から構築する。中断のない通常系は、host key の enrollment、bootstrap、WSL 再起動、OCI image の同期、rebuild、doctor の順に進める。

## 前提

- NixOS-WSL を用意し、`nixos` ユーザーでログインする。[bootstrap script](../../scripts/bootstrap.sh) はこのユーザーと `/home/nixos/dotfiles-wsl` を初回構築の固定値として検査する。
- リポジトリを `~/dotfiles-wsl` へ clone し、作業ツリーを変更のない状態にする。`dotfiles-sops-enroll prepare` は差分と未追跡ファイルがあると開始しない。
- recovery key を読み取り専用の外部媒体から一時的に参照できるようにする。host key は enrollment command が `/var/lib/sops-nix/key.txt` へ生成するため、別ホストの鍵をコピーしない。
- 他のホストと重複しない host ID を決める。ID は63文字以内の小文字の英数字またはハイフンで構成し、英数字で始める。

再現対象は tracked source と `flake.lock` から生成する system と Home Manager の設定である。AI CLI の login session、agentmemory のデータ、host key はホスト固有であり、別ホストから複製しない。AI CLI 本体は bootstrap 時点の upstream 版を取得するため、`flake.lock` の再現対象には含まれない。

## Host key

configured worktree から recovery key と host ID を渡し、候補を作る。

```bash
cd ~/dotfiles-wsl
nix run .#dotfiles-sops-enroll -- prepare \
  --recovery-key /media/offline/recovery-key.txt \
  --host-id desktop-nixos
nix run .#dotfiles-sops-enroll -- status
```

`prepare` の出力にある `PREPARED` の host ID と追加 recipient を確認してから適用する。

```bash
nix run .#dotfiles-sops-enroll -- apply \
  --recovery-key /media/offline/recovery-key.txt \
  --yes
nix run .#dotfiles-sops-enroll -- status
```

新規ホストでは、`apply` が暗号化済みファイルを交換し、host key を昇格して `APPLIED` を表示する。最後の `status` で state が `idle` になったことを確認する。中断した場合や `PENDING` が表示された場合は、自己判断で鍵や候補を消さず、[SOPS enrollment](sops-enrollment.md)の復旧手順へ移る。

変更対象を確認する。

```bash
git diff --check
git diff -- secrets
git status --short
```

`git status --short` に表示される変更は `secrets/.sops.yaml` と `secrets/secrets.yaml` の二つだけにする。bootstrap 前は Git identity が未配備なので、この時点では commit しない。enrollment が完了したら recovery key をホストから取り外す。

## Bootstrap

`nixos` ユーザーから `sudo` を介して実行する。

```bash
cd ~/dotfiles-wsl
sudo bash scripts/bootstrap.sh
```

[bootstrap script](../../scripts/bootstrap.sh) は次の順序で初回 generation を用意する。

| 順序 | 処理 |
|---|---|
| 1 | enrollment、rebuild、bootstrap が共有する operation lock を取得する |
| 2 | active な enrollment がないことを確認する |
| 3 | active な rebuild がないことを確認する |
| 4 | root の Git `safe.directory` に checkout を登録する |
| 5 | flake、lock、暗号化済み secrets、host key の存在と host key の owner、mode を検査する |
| 6 | flake build から見えない未追跡ファイルがないことを確認する |
| 7 | host key で `secrets/secrets.yaml` を復号できることを確認する |
| 8 | AI CLI を upstream から `~/.local/bin` へ配置する |
| 9 | flake が固定した `nixos-rebuild` で boot generation を作る |
| 10 | `/etc/nixos` を `~/dotfiles-wsl` への symlink にする |

## 初回同期

bootstrap が完了したら、PowerShell から NixOS-WSL を停止して起動する。

```powershell
wsl -t NixOS
wsl -d NixOS
```

再ログイン後は通常ユーザーで upstream OCI image を同期し、同じ checkout を通常の rebuild transaction で適用する。

```bash
cd ~/dotfiles-wsl
dotfiles-sync-images
dotfiles-rebuild
```

初回 boot generation の container unit は、Docker cache に upstream image がないため失敗し得る。`dotfiles-sync-images` の後に `dotfiles-rebuild` を実行すると、同期済み image を使って service が収束する。rebuild が別の WSL 再起動を指示した場合は、表示された手順を完了してから検証へ進む。

## 検証

system generation、service、managed file、OCI image、AI CLI、MCP の実状態を検査する。

```bash
dotfiles-doctor
git diff --check
git diff -- secrets
git status --short
```

doctor が成功し、`git status --short` に暗号化済みファイル二つ以外の変更がないことを確認する。sops-nix が配備した Git identity を使い、`secrets/.sops.yaml` と `secrets/secrets.yaml` を同じ commit に記録する。

## 別 host への再現

別ホストでも clone から検証まで同じ順序を使い、ホストごとに新しい host ID と host key を作る。既存ホストの `/var/lib/sops-nix/key.txt` や `~/.config/sops/age/keys.txt` はコピーしない。

新しい enrollment を始める前に、直前のホストで生じた暗号化済み差分を commit し、その repository を利用する全ホストへ同期する。bootstrap 前に差分を退避する必要がある場合は、平文を保存せず、外部媒体へ Git patch を作る。

```bash
git diff --binary -- secrets \
  > /media/offline/desktop-nixos-enrollment.patch
```
