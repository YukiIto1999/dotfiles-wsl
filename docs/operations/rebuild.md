# Rebuild

通常の設定変更は `dotfiles-rebuild` で適用する。source の評価と build は通常ユーザーで行い、system profile の更新と activation だけを昇格する。`nixos-rebuild`、`switch-to-configuration`、system profile を直接操作すると transaction の回復経路から外れるため使わない。

## 計画

適用前に immutable な source snapshot を検査し、candidate、差分、適用方法を確認する。

```bash
cd ~/dotfiles-wsl
dotfiles-rebuild --plan
```

current generation の command より checkout の実装を先に確認するときは flake package を使う。

```bash
nix run .#dotfiles-rebuild -- --plan
```

`--plan` は system profile と runtime を変えない。snapshot、flake check、candidate build は実行するため、Nix store と cache は更新される。upstream OCI image が candidate の manifest と一致しなければ、表示された candidate 内の同期 command を実行してから計画をやり直す。

未追跡ファイルがある場合は `git status --short` で対象を確認し、必要な source は追跡してから再実行する。ログや一時ファイルはリポジトリ外へ移す。ログインユーザーや WSL の default user が変わる計画は host identity migration になるため、通常の rebuild では適用しない。

## 適用

計画と同じ checkout を通常ユーザーから適用する。

```bash
cd ~/dotfiles-wsl
dotfiles-rebuild
```

checkout にだけ新しい rebuild 実装がある場合は次を使う。

```bash
nix run .#dotfiles-rebuild
```

終了 status 0 なら live switch と doctor まで完了している。次の作業へ進める。status 1 なら表示された拒否理由または操作失敗を解消して再実行する。active transaction がある場合は新しい build を始めず、`--status` と案内された回復 command へ進む。終了 status 3 なら transaction は継続中であり、次節の WSL 操作が必要になる。activation の失敗は status 4、doctor の失敗は status 5、引数、transaction、runtime の不整合は status 2 で返る。失敗時は表示された回復 command を保存し、新しい build を始めない。

active な SOPS enrollment がある場合、通常の適用は拒否される。enrollment が generation の作成を待っているときだけ、[SOPS enrollment](sops-enrollment.md)の手順に従って同じ checkout を rebuild する。active rebuild があるという拒否は、先に `--status` で transaction を確認して復旧する。

## WSL の再起動

status 3 で終了したら、出力された PowerShell command を順番どおり実行する。distribution 名、helper、transaction ID がその transaction に固定されているため、次のような汎用 command へ置き換えない。

一段階の変更では、表示された手順が WSL を停止し、同じ transaction の `--resume` を実行する。二段階の変更では、root での中間起動と `--first-boot`、二度目の停止、`--resume` までが一組になる。`--first-boot` を Bash から単独で実行せず、rebuild が表示した PowerShell command をそのまま使う。

再起動手順の途中で止まった場合は `dotfiles-rebuild --status` を実行し、同じ transaction の出力を確認する。新しい `dotfiles-rebuild` は開始しない。

## 再開

active transaction の確認には通常の command を使う。再開は transaction または失敗時に表示された immutable recovery command をそのまま使い、`RECOVERY_HELPER` を表示された絶対 path に置き換える。

```bash
dotfiles-rebuild --status
RECOVERY_HELPER --resume TRANSACTION_ID
```

`--resume` は transaction に固定された candidate の activation または doctor を再試行する。OCI image が不足している場合は、エラーに表示された target 内の `dotfiles-sync-images` を実行し、同じ `--resume` を再実行する。

candidate の適用後に doctor 自体の欠陥が判明した場合だけ、修正済み checkout から表示された forward recovery を実行する。

```bash
nix run .#dotfiles-rebuild -- --forward-recover TRANSACTION_ID
```

新しい candidate の OCI image が不足していれば、出力された同期 command の後に同じ `--forward-recover` を再実行する。作成中の forward recovery を破棄して元の transaction へ戻る場合だけ、案内された次の command を使う。

```bash
nix run .#dotfiles-rebuild -- --cancel-forward-recover TRANSACTION_ID
```

forward recovery が有効な間は、親 transaction に対する `--resume`、`--rollback`、`--abort` を実行しない。

## Rollback

失敗時の案内に rollback が表示された場合だけ、その immutable recovery command をそのまま実行する。`RECOVERY_HELPER` は表示された絶対 path に置き換える。

```bash
RECOVERY_HELPER --rollback TRANSACTION_ID
```

rollback は rebuild 開始時に実行中だった system を回復対象にする。既存の system profile が別 generation を指していても、その profile を回復対象にはしない。回復対象が現行の doctor と OCI 同期の契約を持たない場合、rollback は案内されない。

回復対象の OCI image が不足している場合は、表示された回復対象内の同期 command を実行し、同じ `--rollback` を再実行する。WSL の停止が必要なら status 3 で終了するため、出力された PowerShell command を完了する。

## Abort

失敗時の案内に abort が表示された場合だけ、その immutable recovery command をそのまま実行する。`RECOVERY_HELPER` は表示された絶対 path に置き換える。

```bash
RECOVERY_HELPER --abort TRANSACTION_ID
```

abort は system profile の更新も activation も起きていない transaction を、system を変えずに閉じる。条件を満たさない場合は拒否されるため、`--resume` または案内された `--rollback` を選ぶ。以前の command で開始した transaction に対して checkout の control plane が必要だと案内された場合は、その出力にある `nix run` command を使う。

## 状態確認

```bash
dotfiles-rebuild --status
```

`idle` なら active transaction はない。active な場合は transaction ID と状態を確認し、[再開](#再開)に従って表示済みの immutable recovery command を使う。失敗時に案内されていれば rollback または abort も選べる。status 2 は保存状態か runtime の契約が壊れているため、自分で state directory を編集せず、出力と `git status --short` を保全して原因を調べる。

WSL 再起動の判定は [ADR 0008](../adr/0008-wsl-cold-start-manifest.md)、apply と回復経路は [ADR 0009](../adr/0009-rebuild-effect-routing.md)、doctor の成功判定は [ADR 0011](../adr/0011-doctor-result-report.md)に記録している。入口は [README](../../README.md)、新規ホストの順序は[セットアップ](../getting-started.md)、構成上の責務は[構成概要](../architecture/overview.md)を参照する。
