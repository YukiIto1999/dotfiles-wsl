# Doctor

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

`dotfiles-doctor` は 2 つを見る。この repo が宣言する常駐 service が active か、gateway が MCP の initialize を返すか。前者は systemd が答え、後者は unit が active でも session が張れない場合があるので別に確かめる。

```sh
dotfiles-doctor          # 人が読む形
dotfiles-doctor --json   # 機械が読む形
```

失敗があれば exit 1 で、active でない unit を挙げる。

```sh
systemctl --failed
journalctl -u UNIT -n 30
```

宣言と実装の整合は `nix flake check` が build 前に見る。doctor は実際に動いているかだけを見る。
