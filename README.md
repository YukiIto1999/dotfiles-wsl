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
agentgateway が入口となり、各 stdio MCP server を子プロセスとして起動する。
常駐 process が必要な target だけ、loopback に publish した host port 経由で Docker backend を使う。

stdio target は downstream の session ごとに子プロセスへ複製される。
そのため endpoint を分け、常用する target だけを `default` に置く。
CLI の global config が指すのは `default` だけで、他の endpoint へ繋ぐかは接続側が決める。

```text
AI coding CLI
       |
       | configured URL: default endpoint の URL
       v
agentgateway-default (systemd)      agentgateway-playwright      agentgateway-codex
       |                                   |                            |
       | spawn: stdio MCP                  | spawn                      | spawn
       v                                   v                            v
MCP servers                          playwright                   codex
       |
       | loopback host publish
       v
Docker backends
```

endpoint の一覧と port は `nix eval --json .#nixosConfigurations.nixos.config.my.contract.mcp.endpoints` で引く。

Docker backend の container は同一の Docker network `dotfiles-backends` に属する。container 間の network と host 側の loopback publish は別の境界になる。

リポジトリの主要部分は次の構成。

```text
.
├── flake.nix              unit の収集、NixOS system、package、check の入口
├── flake.lock             input の固定
├── clis/                  AI CLI の共通資産と CLI ごとの配備
├── mcp/                   gateway、MCP target、Docker backend
├── doctor/                実用状態の診断
├── rebuild/               rebuild transaction
├── images/                OCI image inventory と同期
├── sops/                  secret の登録と検証
├── toolchain/             PATH 上の汎用ツールと language server
├── telemetry/             使用量の観測
├── sonarqube/             品質 gate
├── accounts/ git/ cleanup/ commands/ quality/ system/
├── bootstrap/             初回構築
├── secrets/               SOPS で暗号化した secrets
└── docs/                  runbook、architecture、reference
```

責務は repo 直下に置き、層はどの責務でも同じ名前のファイルで表す。
`module.nix` が宣言、`package.nix` が build、`checks.nix` が検証、`impl/` `assets/` `tests/` `fixtures/` `package/` が素材である。
`flake.nix` はこの名前だけを頼りに unit を集めるため、責務を足すとき flake を編集しない。


設計全体は[構成概要](docs/architecture/overview.md)、AI CLI と MCP の境界は[AI tooling](docs/architecture/ai-tooling.md)に記載する。

## 変更

変更対象は[変更箇所一覧](docs/reference/change-map.md)から選ぶ。
生成先を直接直さず、対応する unit の `module.nix`、`assets/`、または暗号化済み secrets を変更する。

通常の変更後は `dotfiles-rebuild --plan` で候補を確認し、`dotfiles-rebuild` で適用する。
この経路が build、activation、検証を一つの transaction として扱う。
開発時の検査とファイルごとの規約は[開発](docs/operations/development.md)を参照する。

OCI image の変更は[OCI image runbook](docs/operations/oci-images.md)、doctor の診断は[doctor runbook](docs/operations/doctor.md)に従う。

## セキュリティ

- host key は `/var/lib/sops-nix/key.txt` に置き、root 所有の `0400` とする。別ホストへコピーせず、通常の rebuild で生成し直さない。
- offline recovery key は読み取り専用の外部媒体で保管する。enrollment と復旧の間だけ接続し、通常運用するホストへ常置しない。
- GitHub PAT は `secrets/secrets.yaml` へ SOPS で暗号化し、fine-grained PAT の権限を用途に必要な範囲へ絞る。`gh auth login` や `gh auth switch` で別経路の credential を作らない。
- agentgateway は認証なしで endpoint ごとの port を listen する。到達できる process を信頼境界の内側として扱う。Docker backend の host publish は `127.0.0.1` に限定する。
- system generation の更新に `nixos-rebuild` を直接使わない。通常変更は `dotfiles-rebuild`、初回構築だけは `bootstrap/impl/bootstrap.sh` を使う。

鍵、credential、通信境界の設計根拠は[セキュリティ設計](docs/architecture/security.md)に記載する。

## ドキュメント

主要な操作と構成文書には、該当する節から直接リンクしている。

## License

[MIT License](LICENSE)
