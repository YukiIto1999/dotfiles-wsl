# 0007. SOPS 鍵の enrollment と通常更新を分離する

## 状態

Accepted

## 背景

従来は `/var/lib/sops-nix/key.txt` と `~/.config/sops/age/keys.txt` に同じ age identity があり、
その recipient だけで `secrets/secrets.yaml` を暗号化していた。この構成では、別ホストへの鍵コピーが
再現手順になり、鍵を失うと復旧できない。通常の rebuild が鍵生成まで担うと、宣言状態の適用と
外部 identity の enrollment も区別できない。

sops-nix は activation 時に既存 identity で secret を復号する。SOPS は `.sops.yaml` の recipient
変更を `sops updatekeys` で暗号文 metadata へ反映する。この二つを別の処理として扱う。

## 決定

runtime identity はホスト固有の age key とし、`/var/lib/sops-nix/key.txt` にだけ置く。
directory は root `0700`、key は root `0400` とする。`sops.age.generateKey = false` を明示し、
通常の rebuild は鍵を生成、交換、削除しない。

別の age identity をオフライン復旧鍵として保管する。host recipient と recovery recipient は
`secrets/.sops.yaml` の同じ age key group に置き、どちらか一方で復号できる構成にする。
新規ホストの enrollment は bootstrap より前に行い、次の順序を守る。

1. recovery identity を読み取り専用の外部媒体へ保管し、その公開 recipient と復号能力を確認する。
2. 新規ホストで host key を生成し、既存 recipient を保持したまま host recipient と recovery recipient を `.sops.yaml` の同じ age key group に追加する。
3. recovery identity で `sops updatekeys secrets/secrets.yaml` を実行する。
4. host identity と recovery identity で暗号文を個別に復号する。
5. recovery identity をホストから取り外す。
6. enrollment 済み host key を使って bootstrap を実行する。

flake の `sops-policy` check は、評価済みの key path、鍵の自動生成禁止、tmpfiles の owner / mode と、
`.sops.yaml` と暗号文 metadata の recipient 集合が一致することを検査する。秘密値は復号しない。

## 現在の移行状態

既存 recipient は `recovery` と命名するが、その秘密鍵は現在も runtime key と home 側に存在する。
host recipient の追加、復旧鍵のオフライン保管、root key の交換、home 複製の削除は未実施である。
実鍵を削除する前に、host identity と recovery identity の双方で復号を実測する。

## 影響

Git と Nix store だけでは新規ホストを起動できず、enrollment にはオフライン復旧 identity が必要になる。
一方、通常更新は外部鍵を変更せず、鍵の紛失や誤交換を activation の副作用として起こさない。
host key を別ホストへコピーしないため、1 台の侵害で他ホストの runtime identity は失われない。

## 一次資料

- [sops-nix README](https://github.com/Mic92/sops-nix/blob/master/README.md)
- [SOPS Key management](https://getsops.io/docs/usage/key-management/)
