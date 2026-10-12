# Secrets

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

暗号化済み secret の正本は `secrets/sops/assets/secrets.json`、復号に使う host key は `/var/lib/sops-nix/key.txt` である。
secret の取得方法は各 consumer の module が所有し、平文 file を配備するものは `sops.secrets`、要求時に復号するものは native credential command を宣言する。

## 編集

通常の編集では、checkout の root で host key を明示して SOPS を起動する。

```bash
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops --config secrets/sops/assets/.sops.yaml secrets/sops/assets/secrets.json
git diff --check -- secrets/sops/assets/secrets.json
git diff -- secrets/sops/assets/secrets.json
```

平文を別ファイル、shell history、Git patch、ログへ書かない。通常の値変更で `sops updatekeys` は要らない。recipient と host key を変える手順は [SOPS の鍵](sops-enrollment.md)にある。

secret を追加するときは、先に値を消費する module に取得方法を宣言し、同じ key path を SOPS で追加する。
平文 file を配備する場合は `sops.secrets` と必要な template または file owner を宣言し、consumer を確認してから `dotfiles-rebuild --plan` と `dotfiles-rebuild` を実行する。
OMP の TypeSafe credential は [`agents/clients/omp/module.nix`](../../agents/clients/omp/module.nix) が宣言する native command で `typesafe/api_key` だけを復号し、取得結果を平文 file や OMP の認証 DB へ保存しない。

MCP front が既存の secret file を起動時に読む場合は、その secret の `restartUnits` に front service を加える。所有境界は [AI tooling](../architecture/ai-tooling.md#container-platform) に従う。

## Identity

default Git identity は常に宣言し、生成された Git 設定から読み込む。work identity は `dotfiles.toolchain.git.workIdentity` が設定されている場合だけ宣言され、指定した Git directory にだけ切り替わる。

identity の値は `identity/module.nix` の SOPS template を介して配備する。同 module は `secrets/sops/impl/user-secret-file.nix` を明示的に import し、user 所有と mode `0600` を一つの helper から設定する。生成後の Git 設定を直接編集せず、暗号化済み secret を編集して rebuild する。

## GitHub account

GitHub account の roster は暗号化済み store が持つ。sops は値だけを暗号化して key の構造を平文で残すので、`accounts` 配下の key が登録済み account の正本であり、`identity/module.nix` はそこから roster を導出する。宣言側に account ID を書かない。`gh` の active user と既定 token になる account は、その entry に `primary` の key を置いて印を付ける。username は `gh` の設定が消費し、token は `gh`、account ごとの GitHub MCP target、Git の credential helper が消費する。

account の追加と削除は store の編集だけで完結する。`accounts` へ entry を足し、`username` と `token` を入れ、`primary` はどれか一つの entry にだけ置く。module も profile も変えない。登録済み account を確かめるには `gh auth status` を使い、`gh auth login` と `gh auth switch` は使わない。token は最小権限にし、平文を module や生成設定へ書かない。

HTTPS の Git は、`github.com` の repository に `gh` の helper が返す primary の token を使う。primary 以外の account でしか読めない owner の repository には、担当する account の entry に `owners` の key を置き、その下に owner 名の key を置いて印を付ける。値は読まず、`primary` と同じく key の有無だけが意味を持つ。

```bash
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops --config secrets/sops/assets/.sops.yaml set secrets/sops/assets/secrets.json \
  '["accounts"]["<account-id>"]["owners"]["<owner>"]' '"true"'
```

`identity/module.nix` は印から account ごとの owner を導出し、`toolchain/git/module.nix` は `https://github.com/<owner>` の credential helper を、その account の token file を読む helper へ置き換える。同じ owner を二つの account に置く構成と、primary に印を置く構成は評価時に拒否する。Git は URL の path を大文字と小文字を区別して照合するため、remote URL の owner は印と同じ表記で書く。remote URL に token を埋め込まない。

## Hindsight

HindsightのLLM provider用credentialは[`capabilities/project-memory/hindsight/backend/module.nix`](../../capabilities/project-memory/hindsight/backend/module.nix)が宣言する`hindsight.env` templateからenvironment fileへ配備する。templateはroot所有のmode `0400`で、更新時に`docker-hindsight.service`を再起動する。既存の`opencode/go_api_key`をcredentialとして使い、endpoint、model、named volume、local model mountはsecret inventoryへ入れず、設定変更はconsumer moduleで行う。

HindsightのAPIは`127.0.0.1:3111`、memory MCP frontは`127.0.0.1:8774`である。client integrationのhookとOpenCode pluginはcredentialを所有せず、`dotfiles-memory`を経由してAPIへ接続する。credentialの値をclient設定、Nix source、ログへ書かない。

retain入力は設定した外部LLMへ送られる。明示的な保存と記憶の収穫の入力はSOPS secretへ追加するものではなく、indicator filteringもsecretやPIIを完全には検出しない。

OCI image digest は secret ではないため、暗号化済みファイルへ移さない。image の取得は [OCI images](oci-images.md)で扱う。

入口は [README](../../README.md)、初回の host key 登録は[セットアップ](getting-started.md)、credential の信頼境界は[セキュリティ設計](../architecture/security.md)を参照する。
