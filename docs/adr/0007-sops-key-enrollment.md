# 0007. SOPS 鍵の enrollment と通常更新を分離する

## 状態

Accepted

## 背景

従来は `/var/lib/sops-nix/key.txt` と `~/.config/sops/age/keys.txt` に同じ age identity があり、その recipient だけで `secrets/secrets.yaml` を暗号化していた。別ホストの再現に秘密鍵のコピーが必要で、同じ identity が runtime、home、復旧用途を兼ねていた。

sops-nix の activation は既存 identity で secret を復号する。SOPS の `updatekeys` は data key を変えず、設定した master key で data key を再暗号化する。通常の rebuild に鍵生成と recipient 更新を混ぜると、宣言状態の適用と外部 identity の enrollment を区別できない。

鍵分離には repository の `.sops.yaml` と `secrets.yaml`、root 領域の host identity という三つの可変状態がある。単純な順次上書きでは、process kill や電断の位置によって設定と暗号文の recipient 集合が食い違う。現在の runtime key と recovery key が同じ環境では、その key を host recipient として追加しても分離にならない。

## 決定

runtime identity はホスト固有の age key とし、`/var/lib/sops-nix/key.txt` にだけ置く。directory は root `0700`、key は root `0400` とする。`sops.age.generateKey = false` を維持し、通常の rebuild は鍵を生成、交換、削除しない。

オフライン復旧用の age identity を別に保管する。`secrets/.sops.yaml` は `keys.recovery` と `keys.hosts.<host-id>` を持ち、全 recipient を同じ age key group に置く。enrollment は既存 recipient を削除しない。既存 host ID の上書きだけでなく、登録済み current identity を別 ID で再登録する操作も rotation なので拒否する。enrollment を許すのは、current identity がない新規ホストと、current identity が recovery identity と同じ移行中ホストだけである。

`dotfiles-sops-enroll` は次の二段階を公開する。

1. `prepare` は作業ツリー全体が clean であることを要求する。recovery identity が現在の暗号文を復号できることを確認し、新 host identity を root 管理の `key.next` に生成する。`.git/dotfiles-sops-enroll/<transaction-id>/secrets` に repository 候補を作り、その候補だけに `sops updatekeys` を実行する。既存 recipient の保持、設定と暗号文の集合一致、重複なし、recovery と next host の復号を確認してから、旧・新 hash を root journal に記録する。tracked file は変更しない。既存ホストでは current system と system profile が同じ generation を指し、その generation contract の暗号文 hash が repository と一致することも開始条件にする。
2. `apply --yes` は repository と候補が prepare 時の hash に一致することを再確認する。同一 filesystem 上で `mv -T --exchange --no-copy` を使い、`secrets/` directory 全体を交換する。新規ホストではそのまま新鍵を昇格する。旧鍵があるホストでは repository 交換後も `key.txt` に旧鍵、`key.next` に新鍵を維持し、新しい system generation が active になるまで `generation-pending` で停止する。

既存ホストの root journal は次の順で進める。

```text
staged → prepared → swap-intent → repo-swapped
→ generation-pending → generation-ready
→ history-close-intent → history-closed
→ key-promoted → verified → complete
```

新規ホストは active key がなく、current system と system profile に managed SOPS generation contract もない環境に限定する。contract があるのに `key.txt` がない環境は、壊れた既存ホストとして拒否する。新規ホストは `repo-swapped` から `key-promoted` へ進み、generation barrier と history closure を使わない。receipt の `freshEnrollment` はこの経路を通った履歴事実であり、bootstrap の現在状態は表さない。

`swap-intent` は directory exchange の直前に記録し、その時点で abort を閉じる。交換の直前と直後に repository 側と退避側の hash と形状を照合する。退避側を削除するのは、directory が candidate 以外を含まず、旧 hash と完全に一致する場合だけである。prepare が root journal 更新前に失敗した場合も、candidate が記録済みの新 hash、または未更新 repository の完全な複製と一致する場合だけ削除する。並行編集などで一致しなければ transaction directory を保全して停止する。再開位置の根拠は状態名だけではなく、旧・新ファイルの SHA-256、current と next の公開 recipient、current system、system profile、残存 generation である。directory exchange、profile history の部分削除、key exchange の直後に停止しても、同じ `apply` が観測値から前進する。`prepared` までだけ `abort` を許可する。

各 NixOS generation は `/etc/dotfiles/sops-generation.json` を持つ。この contract には sops-nix manifest の store path、その manifest が参照する暗号文の store path と SHA-256、同じ manifest を実行する installer を記録する。root helper は manifest 内の全 secret が同じ暗号文と hash を参照することも確認する。`generation-ready` へ進む条件は、current system と system profile の target が一致し、contract の暗号文 hash が transaction の新 hash と等しく、旧鍵と新鍵の両方がその store 暗号文を復号できることである。build 成功だけではこの条件を満たさない。

`/run/booted-system` は barrier に含めない。NixOS-WSL は次回起動時に system profile の `activate` と systemd を実行し、`/run/booted-system` は初回 activation の記録として使う。live switch で current system と profile が収束すれば再起動せずに続行する。boot apply で profile だけが変わった場合は、旧鍵を維持したまま WSL 再起動を待つ。

鍵昇格の前に system profile の generation を列挙する。contract がない、transaction の新 hash と異なる、または新鍵で暗号文を復号できない generation を `history-close-intent` に番号と store path 付きで記録し、その番号だけを `nix-env --delete-generations` で削除する。残存 generation を新鍵で再検証して `history-closed` に進む。`apply --yes` はこの不可逆な rollback history の削除も承認する。削除対象は receipt の `closedGenerations` に残す。

`history-closed` の後にだけ `key.txt` と `key.next` を交換する。current generation の installer を新鍵で実行し、active ciphertext を recovery と current host の双方で再検証する。finalize の直前にも active file の hash を再確認し、検証後に変わっていれば旧鍵を削除しない。成功時だけ旧鍵と worktree backup を削除し、root receipt を残す。

operation lock、candidate、user transaction marker は linked worktree ごとの Git dir ではなく Git common dir に置く。`dotfiles-rebuild` は snapshot 取得から activation 終了まで、bootstrap は全 stage の終了まで同じ lock を保持し、enrollment command との同時実行を拒否する。command 終了後も marker は transaction ID、開始 worktree、phase、旧・新 hash を保持する。bootstrap は active marker があれば停止する。rebuild は `generation-pending` だけを受け入れ、作業ツリーの差分が SOPS の二ファイルだけで、marker の新 hash と一致する場合に限って build と apply を行う。`apply` は generation barrier を検証する直前に marker を `generation-checking` へ進める。未収束なら `generation-pending` へ戻し、root journal が `generation-ready` へ進んだ場合や検証中に停止した場合は `generation-checking` のままにする。これにより、鍵側の状態が進んだ後に通常 rebuild を再許可する窓を作らない。

production enrollment は configured worktree だけに制限し、linked worktree と別 clone を拒否する。root helper の全 transaction operation は 32桁の transaction ID を必須とし、active journal と一致する場合だけ実行する。root journal は repository path と recovery key path を受け取らず、user marker は root helper から読まない。

各中間状態で、active generation の暗号文は active key または手元の recovery identity の少なくとも一方で復号できなければならない。repository 交換から history closure までは旧鍵を active に保ち、新 repository 暗号文は additive な recipient 更新によって旧鍵と新鍵の両方で復号できる。鍵昇格後は、current と全 profile generation が新鍵で復号できる。directory exchange は path の切替を原子的にするが、複数 path を別々に開く並行 reader の snapshot までは保証しない。共通 operation lock で rebuild との並行実行を防ぐ。

root helper は引数を列挙した固定 operation だけ受け付け、recovery key path、repository path、candidate path を root 権限で開かない。candidate ciphertext は stdin で渡す。abort は root journal を先に確定し、user candidate と marker は後から削除する。途中停止で root が idle、user state が残った場合は同じ abort で回収する。production の復号は `systemd-run` の transient service で行い、host identity を systemd credential として `DynamicUser` の verifier へ渡す。verifier は `PrivateNetwork=yes`、`ProtectSystem=strict`、`ProtectHome=yes`、`NoNewPrivileges=yes` と空の環境で SOPS を実行し、平文を `/dev/null` へ捨てる。enrollment は低頻度の管理操作なので NOPASSWD sudo rule を追加しない。NixOS が評価した `config.security.wrapperDir/sudo` の絶対パスで開始時の credential を検証し、Nix store 上の `pkgs.sudo` と呼び出し元の PATH は使わない。

home key の削除と `my.sops.enrollmentState = "enrolled"` への変更は別 phase とする。enrollment command の成功だけを根拠に home key を消さない。doctor の `warn` / `reject` はこの domain state から導出する。

flake check の VM test は test identity だけを使い、sops-nix による activation 復号、production の transient verifier、generation barrier、profile history closure、鍵昇格、current generation の installer 再実行、receipt 完成までを通す。秘密鍵本文を扱う実ホストの migration はこの test で代替せず、別の運用作業として残す。

## 現在の移行状態

repository の recipient metadata は recovery 1件だけで、`my.sops.enrollmentState = "migration"` である。host recipient の追加、root key の交換、home 複製の削除は実環境では未実施である。実環境の current system と system profile も未収束なので、generation contract を含む system を通常 rebuild で配備し、doctor で収束を確認するまで enrollment を実行しない。`dotfiles-sops-enroll` の配備は移行手段の追加であり、実鍵の移行完了ではない。

## 影響

Git と Nix store だけでは新規ホストを起動できず、enrollment にはオフライン recovery identity が必要になる。host key は別ホストへコピーしないため、1台の侵害で他ホストの runtime identity まで共有しない。

prepare は root の `key.next`、root journal、`.git` 配下の候補を作る副作用を持つが、tracked source の変更とは分離され、`prepared` までは abort できる。apply が `swap-intent` を記録した後は、repository 交換前でも前進復旧する。apply の副作用は hash、recipient、transaction ID、generation contract、profile history、receipt で観測でき、同じ command で再開できる。

既存ホストの鍵分離は rollback boundary を作る。enrollment 前の generation は recovery identity だけを復号鍵にしているため、新 host key へ移行した後の標準 rollback 対象には残せない。旧 Git commit へ戻すときは、recovery identity で現行 recipient model へ再暗号化し、新しい generation として build する。旧 store closure の `activate` を直接実行する経路はサポートしない。

## 一次資料

- [sops-nix README](https://github.com/Mic92/sops-nix/blob/master/README.md)
- [SOPS key management](https://getsops.io/docs/usage/key-management/)
- [systemd-run](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)
- [systemd execution environment と credentials](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)
- [GNU Coreutils `mv`](https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html)
- [sops-nix activation script](https://github.com/Mic92/sops-nix/blob/c591bf665727040c6cc5cb409079acb22dcce33c/modules/sops/default.nix#L495-L509)
- [sops-nix generation manifest](https://github.com/Mic92/sops-nix/blob/c591bf665727040c6cc5cb409079acb22dcce33c/modules/sops/manifest-for.nix#L30-L43)
- [NixOS-WSL 起動時の system profile activation](https://github.com/nix-community/NixOS-WSL/blob/add6b01c7ca72240046b5d541a74845423f1ee35/utils/src/shim.rs#L94-L120)
