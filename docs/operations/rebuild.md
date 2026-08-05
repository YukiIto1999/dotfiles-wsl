# Rebuild

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

設定変更は `dotfiles-rebuild` で適用する。NixOS の generation と profile が世代を持つので、適用に失敗しても走っている system は前の generation のまま残る。原因を直して打ち直せばよい。

## 使う

```sh
dotfiles-rebuild --plan   # 変わるものと WSL 再起動の要否を見る
dotfiles-rebuild          # 適用する
```

`dotfiles-rebuild` が `nixos-rebuild switch` に足しているのは 2 つだけである。

**未 commit の変更で適用しない。**flake は tracked file しか見ないので、編集しただけの内容は候補に入らない。気づかずに古い内容を配備しないよう、working tree が汚れていれば止める。

**WSL の再起動要否を判定する。**`/sbin/init` の入れ替えや default user の変更は、`wsl.exe --terminate` を経ないと反映されない。`--plan` が `switch`、`switch-restart`、`boot-restart`、`boot-two-stage` のいずれかを返す。

## 失敗したとき

activation が失敗しても profile は前の generation を指したままか、切り替わった上で一部の unit だけが失敗している。どちらも打ち直しで進む。

```sh
systemctl --failed          # 何が失敗したか
journalctl -u UNIT -n 30    # その理由
dotfiles-rebuild            # 直してから打ち直す
```

前の generation へ戻すときは NixOS の機能をそのまま使う。

```sh
sudo nixos-rebuild --rollback switch
nix profile history --profile /nix/var/nix/profiles/system
```

## WSL を再起動する

`--plan` が `switch` 以外を返したときは、Windows 側から実行する。

```powershell
wsl.exe --terminate NixOS
```

## 直接 nixos-rebuild を呼ばない

PATH の `nixos-rebuild` は拒否する wrapper に置き換えてある。working tree の検査と WSL 再起動の判定を飛ばすためである。初回構築だけは `commands/rebuild/impl/bootstrap.sh` を使う。
