# Secrets

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

暗号化済み secret の正本は `secrets/secrets.yaml`、復号に使う host key は `/var/lib/sops-nix/key.txt` である。secret 名の完全な一覧は、各 consumer に隣接する `sops.secrets` 宣言を正本とし、この文書には複製しない。

## 編集

通常の編集では host key を明示して SOPS を起動する。

```bash
cd ~/dotfiles-wsl
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops secrets/secrets.yaml
git diff --check -- secrets/secrets.yaml
git diff -- secrets/secrets.yaml
```

平文を別ファイル、shell history、Git patch、ログへ書かない。通常の値変更で `sops updatekeys` は要らない。recipient と host key を変える手順は [SOPS の鍵](sops-enrollment.md)にある。

secret を追加するときは、先に値を消費する module に `sops.secrets` と必要な template または file owner を宣言し、同じ key path を SOPS で追加する。consumer の宣言を確認してから `dotfiles-rebuild --plan` と `dotfiles-rebuild` を実行する。

## Identity

default Git identity は常に宣言し、生成された Git 設定から読み込む。work identity は `my.git.workIdentity` が設定されている場合だけ宣言され、指定した Git directory にだけ切り替わる。

identity の値は `sops/module.nix` の SOPS template を介して配備する。生成後の Git 設定を直接編集せず、暗号化済み secret を編集して rebuild する。

## GitHub account

`my.accounts` が GitHub account の roster を生成する。各 account ID の username は `gh` の設定が消費し、token は `gh` と account ごとの GitHub MCP target が消費する。credential の宣言と `gh` への配備は `accounts/module.nix`、MCP の token 読み込みは `mcp/github/module.nix` が所有する。配列の先頭が `gh` の active user と既定 token になる。

account の追加、削除、順序変更では `my.accounts` と対応する暗号化済み key を同時に変更する。`gh auth login` と `gh auth switch` は使わない。token は最小権限にし、平文を module や生成設定へ書かない。

## Agentmemory

Agentmemory の LLM provider 用 credential は `containers/agentmemory/module.nix` が宣言する SOPS template から environment file へ配備する。template の更新は agentmemory container の unit を再起動する。`mcp/memory/module.nix` は backend の型付き endpoint と client version を読み、credential は所有しない。

endpoint、model、保存領域は secret inventory ではない。credential の値だけを SOPS で編集し、設定変更は consumer module で行う。

## Crawl4AI

Crawl4AI の API token は `containers/crawl4ai/module.nix` が宣言し、root 所有の environment file から container へ渡す。同じ unit が user 所有の token file path を型付き contract で公開し、`mcp/crawl4ai/module.nix` の front が読む。MCP unit は SOPS の宣言を直接参照しない。

## SearXNG

SearXNG の server secret は `containers/searxng/module.nix` が設定 template に差し込み、root 所有の設定ファイルへ配備する。template の更新は SearXNG container の unit を再起動する。`mcp/searxng/module.nix` は backend の型付き endpoint だけを読む。

検索設定や OCI image digest は secret ではないため、暗号化済みファイルへ移さない。設定は SearXNG module、image の取得は [OCI images](oci-images.md)で扱う。

入口は [README](../../README.md)、初回の host key 登録は[セットアップ](getting-started.md)、credential の信頼境界は[セキュリティ設計](../architecture/security.md)を参照する。
