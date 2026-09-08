# OCI images

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

container は `pull = "never"` で起動する。宣言した digest の image が事前に無いと起動しない。`dotfiles-sync-images` がその事前配置を行う。

## 使う

```sh
dotfiles-sync-images --status   # 足りない image と pin の切れた image を挙げる。exit 1 なら未同期
dotfiles-sync-images            # 足りないものを pull し、pin を付け直す
```

image が既にあるかは docker が答える。同期の状態を別に記録しない。

## prune から守る

digest だけを指定して pull した image は tag を持たず、`docker image prune` はこれを dangling として消す。rebuild が container を止めている間に `docker-build-artifact-gc.timer` が重なると、宣言済みの image が消えて container が起動しなくなる。`dotfiles-sync-images` は `dotfiles-pinned/<repository>:<tag>` の tag を付け、prune の対象から外す。上流と同じ tag を付けないのは、同じ tag を使う別 project の image を奪わないためである。

digest を更新すると pin は新しい image へ移り、古い image は dangling として GC が回収する。

## digest を更新する

固定する digest は `dotfiles-image-digest` で registry から取る。

```sh
dotfiles-image-digest searxng/searxng:latest
```

得た値を宣言した unit の `digest` へ書き、`dotfiles-sync-images` と `dotfiles-rebuild` を実行する。

**index digest を使う。**`docker pull repo:tag` が解決するのは index で、per-arch の manifest digest とは意味が違う。

## 検査

`oci-image-contract` が、upstream image は digest で固定されていること、参照が repository と digest に整合すること、全 container が `pull = "never"` であることを見る。`oci-image-sync-behavior` は docker を差し替えた実行で、不足分だけの pull、pin の付与、同期済みでの無操作、pin 切れの検出を見る。
