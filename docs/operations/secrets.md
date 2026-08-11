# Secrets

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

暗号化済み secret の正本は `sops/assets/secrets.yaml`、復号に使う host key は `/var/lib/sops-nix/key.txt` である。secret 名の完全な一覧は、各 consumer に隣接する `sops.secrets` 宣言を正本とし、この文書には複製しない。

## 編集

通常の編集では host key を明示して SOPS を起動する。

```bash
cd ~/dotfiles-wsl
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops --config sops/assets/.sops.yaml sops/assets/secrets.yaml
git diff --check -- sops/assets/secrets.yaml
git diff -- sops/assets/secrets.yaml
```

平文を別ファイル、shell history、Git patch、ログへ書かない。通常の値変更で `sops updatekeys` は要らない。recipient と host key を変える手順は [SOPS の鍵](sops-enrollment.md)にある。

secret を追加するときは、先に値を消費する module に `sops.secrets` と必要な template または file owner を宣言し、同じ key path を SOPS で追加する。consumer の宣言を確認してから `dotfiles-rebuild --plan` と `dotfiles-rebuild` を実行する。

## Identity

default Git identity は常に宣言し、生成された Git 設定から読み込む。work identity は `dotfiles.toolchain.git.workIdentity` が設定されている場合だけ宣言され、指定した Git directory にだけ切り替わる。

identity の値は `accounts/module.nix` の SOPS template を介して配備する。同 module は `sops/impl/user-secret-file.nix` を明示的に import し、user 所有と mode `0600` を一つの helper から設定する。生成後の Git 設定を直接編集せず、暗号化済み secret を編集して rebuild する。

## GitHub account

`dotfiles.accounts` が GitHub account の roster を生成する。各 account ID の username は `gh` の設定が消費し、token は `gh` と account ごとの GitHub MCP target が消費する。credential の宣言と `gh` への配備は `accounts/module.nix`、MCP の token 読み込みは `mcp/github/module.nix` が所有する。配列の先頭が `gh` の active user と既定 token になる。

account の追加、削除、順序変更では `dotfiles.accounts` と対応する暗号化済み key を同時に変更する。`gh auth login` と `gh auth switch` は使わない。token は最小権限にし、平文を module や生成設定へ書かない。

## Agentmemory

Agentmemory の LLM provider 用 credential は `containers/agentmemory/module.nix` が宣言する SOPS template から environment file へ配備する。template の更新は agentmemory container の unit を再起動する。`mcp/memory/module.nix` は backend の型付き endpoint と client version を読み、credential は所有しない。

endpoint、model、保存領域は secret inventory ではない。credential の値だけを SOPS で編集し、設定変更は consumer module で行う。

## Crawl4AI

Crawl4AI の API token は `containers/crawl4ai/module.nix` が宣言し、root 所有の environment file から container へ渡す。同じ unit が user 所有の token file path を型付き contract で公開し、`mcp/crawl4ai/module.nix` の front が読む。MCP unit は SOPS の宣言を直接参照しない。

## SearXNG

SearXNG の server secret は `containers/searxng/module.nix` が設定 template に差し込み、root 所有の設定ファイルへ配備する。template の更新は SearXNG container の unit を再起動する。`mcp/searxng/module.nix` は backend の型付き endpoint だけを読む。

検索設定や OCI image digest は secret ではないため、暗号化済みファイルへ移さない。設定は SearXNG module、image の取得は [OCI images](oci-images.md)で扱う。

## SonarQube database password

SonarQube の database password は `containers/sonarqube/module.nix` が root 所有の server 用、PostgreSQL 用 environment file へ展開する。template の更新は対応する container unit を再起動する。

## SonarQube admin password の初回登録

admin password は `containers/sonarqube/module.nix` が宣言し、user 所有の runtime file path を型付き contract で公開する。初回登録では、provision service が SonarQube の初期値 `admin` を SOPS の宣言値へ変更する。server が未起動で失敗すると 60 秒後に再試行する。成功後は inactive へ戻り、timer が 1 時間ごとに再実行する。

この自動処理は初回登録専用である。稼働済み server の password rotation には使わない。

## SonarQube admin password rotation

稼働済み server の password は secret file の差し替えでは変わらない。SonarQube 側と MCP front が異なる password を使う時間を短くするため、次の順で変更する。

1. SonarQube に admin でログインし、server 側の admin password を新しい値へ変更する。
2. host key を指定して SOPS を開き、`sonarqube/admin_password` を同じ値へ更新する。
3. `dotfiles-rebuild` を実行し、runtime secret file を更新する。
4. `sudo systemctl restart mcp-front-sonarqube.service` を実行し、front に新しい値を読み込ませる。

admin secret の更新で front を自動再起動しない。SonarQube 側の変更前に front だけが新しい値を読むと認証できなくなるためである。provision service と MCP front は型付き contract を読み、MCP unit は SOPS を直接参照しない。

入口は [README](../../README.md)、初回の host key 登録は[セットアップ](getting-started.md)、credential の信頼境界は[セキュリティ設計](../architecture/security.md)を参照する。
