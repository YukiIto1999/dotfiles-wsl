# dotfiles-wsl

WSL2 上の NixOS を日常運用し、同じ構成を別ホストへ再現するための flake。

## 概要

`flake.nix` と `flake.lock` から NixOS の system generation と Home Manager 設定を構築する。
ホスト設定だけでなく、AI コーディング CLI の共通ルール、skills、agents、MCP、SOPS で暗号化した secrets も同じリポジトリで管理する。

通常の checkout は `~/dotfiles-wsl` に置く。
初回構築後の `/etc/nixos` は、この checkout を指す symlink になる。
設定の正本は checkout 内の Nix 宣言と共有ファイルであり、生成済みの設定ファイルを直接編集しない。

主な管理対象は次のとおり。

- NixOS-WSL、Nix、Home Manager、font、日常利用する command
- AI コーディング CLI の設定と共通ルール
- agentgateway、MCP server、必要な Docker backend
- Git identity、GitHub PAT、backend credential などの暗号化済み secrets

新しいホストを作る場合は、[新規構築](docs/operations/getting-started.md)から始める。

## 運用

通常操作は `nixos` ユーザーで `~/dotfiles-wsl` から実行する。
適用前に変更内容を確認し、問題がなければ同じ checkout を適用する。

```bash
cd ~/dotfiles-wsl
dotfiles-rebuild --plan
dotfiles-rebuild
```

`dotfiles-rebuild` が WSL の停止と起動を求めた場合は、表示された手順に従う。
中断や復旧を含む扱いは [rebuild runbook](docs/operations/rebuild.md)を参照する。

upstream OCI image の現在値を確認し、宣言した digest に同期する command は次の二つ。
新規構築時と upstream image の更新時は、同期後に `dotfiles-rebuild` を実行する。

```bash
dotfiles-sync-images --status
dotfiles-sync-images
```

適用後の system generation、systemd service、managed file、OCI image、AI CLI、MCP の実状態は doctor で検査する。

```bash
dotfiles-doctor
```

通常の secret 編集はホスト固有の age key を明示して行い、編集後に `dotfiles-rebuild` を実行する。
鍵の enrollment や復旧は別手順なので、[secrets runbook](docs/operations/secrets.md)と[SOPS enrollment](docs/operations/sops-enrollment.md)を参照する。

```bash
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops ~/dotfiles-wsl/secrets/secrets.yaml
```

保守用 devShell を使う checkout では、`.envrc` を一度だけ許可する。以後は checkout へ入ると `flake.lock` に固定した toolchain が有効になる。

```bash
cd ~/dotfiles-wsl
direnv allow
```

## 構成

AI CLI は個別の MCP server へ直接接続しない。
agentgateway が入口となり、常駐する各 MCP front へ loopback の HTTP で接続する。
常駐 process が必要な target だけ、loopback に publish した host port 経由で Docker backend を使う。

MCP front は target ごとの systemd service として常駐する。
gateway は loopback の HTTP へ接続するだけで、子プロセスを起動しない。
downstream の session が増えても process は増えない。

```text
AI coding CLI
       |
       | configured URL: gateway の URL
       v
agentgateway (systemd)
       |
       | HTTP: loopback
       v
常駐 MCP front (target ごとの systemd service)
       |
       | loopback host publish
       v
Docker backends
```

front の一覧と port は `nix eval --json .#nixosConfigurations.nixos.config.my.contract.mcp.fronts` で引く。

Docker backend の container は同一の Docker network `dotfiles-backends` に属する。container 間の network と host 側の loopback publish は別の境界になる。

リポジトリの主要部分は次の構成。

```text
.
├── flake.nix              unit の収集、NixOS system、package、check の入口
├── flake.lock             input の固定
├── host/                  この機械の語彙、WSL 統合、Nix 設定
├── accounts/              account と identity
├── clis/                  AI CLI の共通資産と CLI ごとの配備
├── mcp/                   gateway、MCP target、その application module
├── toolchain/             PATH 上の汎用ツール、language server、git、静的解析
├── telemetry/             使用量の観測
├── containers/            application 固有の container backend と共通 schema、helper、OCI image 同期
├── artifacts/             生成設定の登録簿
├── commands/              運用 command の生成と実体
├── sops/                  secret の配線
├── gates/                 repo 自身の検査
├── secrets/               SOPS で暗号化した secrets
└── docs/                  runbook、architecture、reference
```

`containers/` は container 配備の共通層と application 固有の backend を所有する。Agentmemory、Crawl4AI、SearXNG の backend は各 `containers/` unit、MCP front は対応する `mcp/` unit が所有する。分離途中の application 固有宣言は `toolchain/sonarqube/` だけに残る。

責務は repo 直下に置き、層はどの責務でも同じ名前のファイルで表す。
`module.nix` が宣言、`package.nix` が build、`checks.nix` が検証、`impl/` `assets/` `package/` `fixtures/` が素材である。振る舞いの検証も `checks.nix` に置き、`fixtures/` はその入力を持つ。
`flake.nix` はこの名前だけを頼りに unit を集めるため、責務を足すとき flake を編集しない。


設計全体は[構成概要](docs/architecture/overview.md)、AI CLI と MCP の境界は[AI tooling](docs/architecture/ai-tooling.md)に記載する。

## 変更

変更対象は[変更箇所一覧](docs/reference/change-map.md)から選ぶ。
生成先を直接直さず、対応する unit の `module.nix`、`assets/`、または暗号化済み secrets を変更する。

通常の変更後は `dotfiles-rebuild --plan` で候補を確認し、`dotfiles-rebuild` で適用する。
未 commit の変更で適用しないことと、WSL の再起動要否の判定を、この経路が行う。世代と rollback は NixOS が持つ。
開発時の検査とファイルごとの規約は[開発](docs/operations/development.md)を参照する。

OCI image の変更は[OCI image runbook](docs/operations/oci-images.md)、doctor の診断は[doctor runbook](docs/operations/doctor.md)に従う。

## セキュリティ

- host key は `/var/lib/sops-nix/key.txt` に置き、root 所有の `0400` とする。別ホストへコピーせず、通常の rebuild で生成し直さない。
- offline recovery key は読み取り専用の外部媒体で保管する。enrollment と復旧の間だけ接続し、通常運用するホストへ常置しない。
- GitHub PAT は `secrets/secrets.yaml` へ SOPS で暗号化し、fine-grained PAT の権限を用途に必要な範囲へ絞る。`gh auth login` や `gh auth switch` で別経路の credential を作らない。
- agentgateway と各 front は認証なしで loopback の port を listen する。到達できる process を信頼境界の内側として扱う。Docker backend の host publish は `127.0.0.1` に限定する。
- system generation の更新に `nixos-rebuild` を直接使わない。通常変更は `dotfiles-rebuild`、初回構築だけは `commands/rebuild/impl/bootstrap.sh` を使う。

鍵、credential、通信境界の設計根拠は[セキュリティ設計](docs/architecture/security.md)に記載する。

## ドキュメント

主要な操作と構成文書には、該当する節から直接リンクしている。

## License

[MIT License](LICENSE)
