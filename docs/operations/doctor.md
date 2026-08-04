# Doctor

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

`dotfiles-doctor` は 3 つを見る。この repository が宣言する常駐 service が active か、gateway が MCP の initialize を返すか、宣言した target すべての tool が `tools/list` に現れるか。unit が active でも session が張れないこと、session が張れても upstream が fanout で落ちて tool が消えることがあるので、三段に分けて確かめる。

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
