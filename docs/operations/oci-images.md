# OCI images

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

container は `pull = "never"` で起動する。宣言した digest の image が事前に無いと起動しない。`dotfiles-sync-images` がその事前配置を行う。

## 使う

```sh
dotfiles-sync-images --status   # 足りない image を挙げる。exit 1 なら未同期
dotfiles-sync-images            # 足りないものを pull する
```

image が既にあるかは docker が答える。同期の状態を別に記録しない。

## digest を更新する

固定する digest は `dotfiles-image-digest` で registry から取る。

```sh
dotfiles-image-digest searxng/searxng:latest
```

得た値を宣言した unit の `digest` へ書き、`dotfiles-sync-images` と `dotfiles-rebuild` を実行する。

**index digest を使う。**`docker pull repo:tag` が解決するのは index で、per-arch の manifest digest とは意味が違う。

## 検査

`oci-image-contract` が、upstream image は digest で固定されていること、参照が repository と digest に整合すること、全 container が `pull = "never"` であることを見る。
