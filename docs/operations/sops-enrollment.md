# SOPS の鍵

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

secret は `sops/assets/secrets.yaml` に age で暗号化して置く。復号できるのは host 鍵と recovery 鍵の 2 つで、`sops/assets/.sops.yaml` がその recipient を宣言する。

## 鍵の置き場

| 鍵 | 置き場 | 権限 |
|---|---|---|
| host | `/var/lib/sops-nix/key.txt` | root のみ、0400 |
| recovery | machine の外 | 運用者が保管する |

host 鍵は sops-nix が activation 時に読む。**home や repo に複製を置かない。**複製があると、その場所を読めるすべての process が全 secret を復号できる。

recovery 鍵は host 鍵を失ったときの唯一の復元手段になる。**machine の中に置くと復元手段にならない。**

## secret を編集する

```sh
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops --config ~/dotfiles-wsl/sops/assets/.sops.yaml \
  ~/dotfiles-wsl/sops/assets/secrets.yaml
dotfiles-rebuild
```

`secrets.yaml` は flake 経由で store に入るので、編集しただけでは `/run/secrets` に反映されない。rebuild が要る。

## 新しい host を登録する

```sh
age-keygen -o host.key                       # 新 host で生成する
sudo install -m 0400 -o root -g root host.key /var/lib/sops-nix/key.txt
```

生成した公開鍵を `sops/assets/.sops.yaml` の `keys` に host anchor として追加し、`creation_rules` から参照する。既存の鍵を持つ machine で再暗号化する。

```sh
SOPS_AGE_KEY_FILE=/media/offline/recovery-key.txt \
  sops --config sops/assets/.sops.yaml updatekeys sops/assets/secrets.yaml
```

新しい鍵で復号できることを確かめてから、古い recipient を外す。**確かめる前に外すと全 secret を失う。**

```sh
SOPS_AGE_KEY_FILE=host.key \
  sops --config sops/assets/.sops.yaml decrypt sops/assets/secrets.yaml > /dev/null
```

## 検査

`sops-policy` が宣言と暗号文の recipient の一致と、鍵が 2 つあることを見る。`sops-secret-file-mode` が home に置く secret の mode と owner を見る。
