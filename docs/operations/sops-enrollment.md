# SOPS enrollment

新規ホストと既存ホストの鍵分離には `dotfiles-sops-enroll` を使う。host key を別ホストからコピーせず、通常の rebuild や手作業で `/var/lib/sops-nix/key.txt` を生成、交換しない。

## 前提

- recovery key を読み取り専用の外部媒体から一時的に接続する。指定する path は絶対 path とし、symlink ではない読み取り可能な通常ファイル、mode `0400` または `0600`、hard link 数1でなければならない。ファイルには age identity を1件だけ入れる。
- `~/dotfiles-wsl` を configured worktree として使う。linked worktree と別 clone からの `prepare`、`apply`、`status`、`abort` は拒否される。
- `secrets/.sops.yaml` と `secrets/secrets.yaml` を含む作業ツリー全体を commit 済みにし、未追跡ファイルも残さない。
- 63文字以内の小文字の英数字とハイフンからなり、英数字で始まる一意の host ID を決める。登録済み ID の再利用は rotation として拒否される。
- active rebuild を完了または復旧する。既存ホストでは current system と system profile を収束させ、generation contract を含む current generation を配備しておく。

秘密値や recovery key の内容を端末、文書、Git patch に出力しない。

## Prepare

configured worktree から recovery key と host ID を渡す。
`HOST_ID` は前提で決めた値に置き換える。

```bash
cd ~/dotfiles-wsl
nix run .#dotfiles-sops-enroll -- prepare \
  --recovery-key /absolute/path/to/recovery-key.txt \
  --host-id HOST_ID
nix run .#dotfiles-sops-enroll -- status
```

`prepare` は recovery identity で現在の暗号文を復号し、新しい host identity と暗号化済み候補を作って両 identity で検証する。tracked file はまだ変更しない。出力の `PREPARED` に表示された host ID と追加 recipient を、接続した recovery key の内容を表示せずに確認する。

作業ツリーの差分、未追跡ファイル、active transaction、configured worktree、recovery key の条件で拒否された場合は、表示された条件だけを直して `prepare` をやり直す。生成途中のファイルを手作業で削除しない。`status` が active transaction を返す場合は `apply` または許可される段階での `abort` を選ぶ。

## Apply

確認した transaction を明示的に適用する。

```bash
nix run .#dotfiles-sops-enroll -- apply \
  --recovery-key /absolute/path/to/recovery-key.txt \
  --yes
```

`--yes` は暗号化済みファイルの交換に加え、既存ホストで新しい host key が復号できない古い system profile generation の削除も承認する。新規ホストでは `APPLIED` が表示されるまで進み、既存ホストでは generation の作成が必要なら `PENDING` で停止する。

`apply` の途中で終了した場合は、候補、host key、暗号化済みファイルを手作業で戻さない。同じ recovery key を接続したまま、[再開](#再開)へ進む。

## Generation

`PENDING: activate the prepared SOPS generation` が表示された既存ホストだけで実行する。

```bash
cd ~/dotfiles-wsl
nix run .#dotfiles-rebuild
```

rebuild が WSL の停止を指示した場合は、表示された PowerShell command を最後まで実行する。rebuild transaction が完了したら、同じ recovery key でもう一度 `apply` する。

```bash
nix run .#dotfiles-sops-enroll -- apply \
  --recovery-key /absolute/path/to/recovery-key.txt \
  --yes
```

current system と system profile が準備済み暗号文を使う generation に一致し、旧 host key と新 host key の双方で復号できる場合だけ、古い generation の整理と key の昇格へ進む。

## 再開

中断後は configured worktree から状態を確認する。`status` は recovery key の path を受け取らない。

```bash
cd ~/dotfiles-wsl
nix run .#dotfiles-sops-enroll -- status
```

`generation-pending` なら generation を作成してから同じ `apply` を再実行する。`generation-checking`、repository 交換後、key 昇格の途中では rebuild を始めず、同じ `apply` を再実行する。`apply` は記録と実ファイル、current system、system profile、残存 generation を照合して再開位置を決める。

候補または退避側が transaction の記録と一致しないというエラーでは、表示された path を保全して停止する。ファイルを削除、編集せず、状態と `git status --short` を記録する。

## Abort

`prepare` の完了後、repository 交換を開始する前までなら取り消せる。`abort` は recovery key の path と `--yes` を受け取らない。

```bash
nix run .#dotfiles-sops-enroll -- abort
```

`abort` が交換開始後の状態を理由に拒否された場合は rollback せず、同じ `apply` で前進復旧する。孤立した staged key や、root 側の abort 後に残った user state も同じ `abort` が安全条件を確認して回収する。

## 完了確認

`APPLIED` の後に状態と暗号化済み差分を確認する。

```bash
nix run .#dotfiles-sops-enroll -- status
git diff --check
git diff -- secrets
git status --short
```

enrollment の状態が `idle` で、変更が `secrets/.sops.yaml` と `secrets/secrets.yaml` の二つだけなら鍵の登録は完了である。既存ホストでは rebuild も収束したことを確認する。

```bash
dotfiles-rebuild --status
dotfiles-doctor
```

新規ホストではこれらの command がまだ current generation にないため、[セットアップ](../getting-started.md)の bootstrap、初回同期、検証へ進む。この時点で recovery key をホストから取り外す。Git identity を利用できる環境で二つのファイルを同じ commit に記録し、その repository を使う全ホストへ同期する。別ホストの enrollment は同期が済んでから始める。

鍵分離と中断復旧の根拠は [ADR 0007](../adr/0007-sops-key-enrollment.md)に記録している。入口は [README](../../README.md)、新規ホスト全体の順序は[セットアップ](../getting-started.md)、鍵と credential の境界は[セキュリティ設計](../architecture/security.md)を参照する。通常の秘密値編集は [Secrets](secrets.md)で扱う。
