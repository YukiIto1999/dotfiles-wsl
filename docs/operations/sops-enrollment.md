# SOPS の鍵

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

secret は `secrets/sops/assets/secrets.json` に age で暗号化して置く。復号できるのは各 host の鍵と recovery 鍵で、`secrets/sops/assets/.sops.yaml` がその recipient を宣言する。複数の host が同じ暗号文を共有するため、host 鍵は host の数だけ recipient に並ぶ。

## 鍵の置き場

| 鍵 | 置き場 | 権限 |
|---|---|---|
| host | `/var/lib/sops-nix/key.txt` | root のみ、0400 |
| recovery | machine の外 | 運用者が保管する |

host 鍵は sops-nix が activation 時に読む。**home や repo に複製を置かない。**複製があると、その場所を読めるすべての process が全 secret を復号できる。host 鍵は host ごとに生成し、他の host へ複製しない。

recovery 鍵は host 鍵を失ったときの唯一の復元手段になる。**machine の中に置くと復元手段にならない。**

## secret を編集する

checkout の root で実行する。

```sh
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops --config secrets/sops/assets/.sops.yaml secrets/sops/assets/secrets.json
dotfiles-rebuild
```

`secrets.json` は flake 経由で store に入るので、編集しただけでは `/run/secrets` に反映されない。rebuild が要る。

## 新しい host を登録する

```sh
age-keygen -o host.key                       # 新 host で生成する
sudo install -m 0400 -o root -g root host.key /var/lib/sops-nix/key.txt
```

生成した公開鍵を `secrets/sops/assets/.sops.yaml` の `keys` に `host-<host-id>` anchor として追加し、`creation_rules` から参照する。同じ host ID の [`profiles/hosts/`](../../profiles/hosts) profile を用意し、既存の鍵を持つ machine で再暗号化する。

```sh
SOPS_AGE_KEY_FILE=/media/offline/recovery-key.txt \
  sops --config secrets/sops/assets/.sops.yaml updatekeys secrets/sops/assets/secrets.json
```

併用する host の recipient は外さない。外すのは退役した host の分だけで、外す前に残す鍵で復号できることを確かめる。**確かめる前に外すと全 secret を失う。**

```sh
SOPS_AGE_KEY_FILE=host.key \
  sops --config secrets/sops/assets/.sops.yaml decrypt secrets/sops/assets/secrets.json > /dev/null
```

## 検査

`sops-policy` が、`keys` の宣言、`creation_rules` の参照、暗号文の recipient の三者一致、anchor と recipient の重複の不在、recovery anchor がちょうど一つで `host-` anchor が一つ以上あること、登録済み host に対応する anchor があることを見る。`sops-secret-file-mode` が home に置く secret の mode と owner を見る。
