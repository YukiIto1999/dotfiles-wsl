# OCI images

`dotfiles-sync-images` は current generation または指定された immutable target が宣言する upstream image だけを Docker cache へ同期する。Nix が生成して `imageFile` から load する image は pull 対象に含めない。

## 状態確認

current generation の upstream image を読み取り専用で確認する。

```bash
dotfiles-sync-images --status
```

status 0 は全 upstream image が固定 digest と一致している。status 1 は未同期、同期失敗の記録、Docker cache の不一致、image sync lock の競合を表す。status 2 は manifest、state directory、lock、同期記録の契約が不正である。`--status` は image を pull せず、active rebuild を検査しない。同期 state が未作成でも directory や lock を作らない。

## 同期

current generation の upstream image を通常ユーザーで同期する。`sudo` は使わない。

```bash
dotfiles-sync-images
dotfiles-sync-images --status
```

一つの image の取得に失敗しても残りの image は続行され、終了時に失敗が集約される。失敗した image は network、registry、Docker daemon を確認して同じ command を再実行する。古い image は削除されない。

active SOPS enrollment による拒否では enrollment を完了または abort してから同期する。別の同期処理や repository operation が進行中なら、先行処理を完了して再実行する。

## Digest の更新

upstream image を宣言する `modules/mcp/servers/<name>.nix` で repository、digest、digest を含む image reference を同時に変更する。candidate の command を checkout から実行し、新しい manifest に対する状態を確認して同期する。

```bash
cd ~/dotfiles-wsl
nix run .#dotfiles-sync-images -- --status
nix run .#dotfiles-sync-images
nix run .#dotfiles-sync-images -- --status
dotfiles-rebuild
```

最初の `--status` が status 1 になるのは、新しい digest がまだ Docker cache にない通常の状態である。同期後も status 1 なら rebuild へ進まない。status 2 では source と manifest の生成契約を直してから再評価する。

## Active rebuild

rebuild が OCI image の不足で止まった場合は、エラーに表示された target 内の絶対 path をそのまま実行する。

```text
Run: /nix/store/<target-system>/sw/bin/dotfiles-sync-images
```

active rebuild 中に同期できるのは、その transaction の candidate、回復対象、または許可された forward recovery candidate と同じ manifest を持つ command だけである。状態が `complete` の場合は回復対象の command だけを同期に使える。checkout の `dotfiles-sync-images` へ置き換えない。同期後は、停止時に選んでいた同じ `--resume`、`--rollback`、`--forward-recover` を再実行する。

状態が `rolled-back`、`aborted`、`cancelled`、`superseded` の rebuild、壊れた rebuild、SOPS enrollment に結び付いた rebuild、別 target の command は同期を拒否する。拒否時は `dotfiles-rebuild --status` で active transaction を確認し、rebuild が表示する回復経路を完了する。

## 終了 status

| status | 次の動作 |
|---:|---|
| `0` | 対象の upstream image は同期済み。rebuild または再開操作へ進む |
| `1` | 出力された未同期、取得失敗、競合、transaction の拒否理由を解消して同じ target の command を再実行する |
| `2` | state や manifest を手作業で修復せず、実行した command、出力、rebuild の状態を保全して契約違反を調べる |

registry 取得を分離した理由は [ADR 0012](../adr/0012-explicit-oci-image-sync.md)、Docker cache と稼働 container の検査は [ADR 0013](../adr/0013-oci-runtime-convergence.md)、activation 前の同期条件は [ADR 0014](../adr/0014-oci-activation-readiness.md)に記録している。入口は [README](../../README.md)、新規ホストの同期順序は[セットアップ](getting-started.md)、container と MCP backend の関係は [AI tooling](../architecture/ai-tooling.md)を参照する。
