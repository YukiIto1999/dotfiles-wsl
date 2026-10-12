# OCI images

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

常駐containerは `pull = "never"` で起動し、宣言したdigestのimageが事前に無いと起動しない。
常駐containerまたは必要時だけ起動するruntime imageを選択したhostに、`dotfiles-sync-images`を配備する。
どちらも選択しないhostにはこのcommandがないため、以下の手順は実行しない。
runtime imageは`dotfiles.platform.containers.runtimeImages`へ固定参照を登録し、同期だけのためにendpointや常駐unitを作らない。

## 使う

rebuild後のactive hostでは、配備されたcommandを短い名前で実行する。

```sh
dotfiles-sync-images --status   # 足りない image と pin の切れた image を挙げる。exit 1 なら未同期
dotfiles-sync-images            # 足りないものを pull し、pin を付け直す
```

checkoutから対象hostを明示して実行する場合は、host構成のcommandを直接指定する。

```sh
nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages -- --status
nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages
```

image が既にあるかは docker が答える。同期の状態を別に記録しない。

## prune から守る

digest だけを指定して pull した image は tag を持たず、`docker image prune` はこれを dangling として消す。rebuild が container を止めている間に `docker-build-artifact-gc.timer` が重なると、宣言済みの image が消えて container が起動しなくなる。`dotfiles-sync-images` は `dotfiles-pinned/<repository>:<tag>` の tag を付け、prune の対象から外す。上流と同じ tag を付けないのは、同じ tag を使う別 project の image を奪わないためである。

同じtagのdigestを更新するとpinは新しいimageへ移り、他の参照がない古いimageはdanglingとしてGCの対象になる。
宣言のtag自体を変えた場合は古いpinが残るため、切替完了後に使用中のcontainerと現行の宣言から参照されていないことを確認し、その古いpinだけを外す。

## digest を更新する

固定する digest は `dotfiles-image-digest` で registry から取る。

```sh
dotfiles-image-digest ghcr.io/vectorize-io/hindsight:latest
```

得た値を宣言したunitの`digest`へ書き、checkoutから対象hostの`syncImages` commandを実行して新しいimageを事前に同期する。
変更のcommit後に`dotfiles-rebuild --plan`で切替条件を確認してから配備する。

`dotfiles-image-digest`はこのhostが使うlinux/amd64のmanifest digestを返す。
tagのindex digestとは区別し、commandの出力をそのまま宣言へ固定する。

## 検査

`oci-image-contract` が、upstream image は digest で固定されていること、参照が repository と digest に整合すること、全 container が `pull = "never"` であることを見る。`oci-image-sync-behavior` は docker を差し替えた実行で、不足分だけの pull、pin の付与、同期済みでの無操作、pin 切れの検出を見る。
