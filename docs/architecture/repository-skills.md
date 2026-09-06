# 外部リポジトリ所有Skillの構成

**読み手:** 外部リポジトリが所有するSkillをこのホストのエージェントへ取り込む設計と契約を理解・保守する人。

外部リポジトリが所有するSkillは、owner repositoryから直接取得する。`dotfiles-wsl`は固定したコミットから採用対象を登録し、`dotfiles.skills.registry`でローカルSkillと単一の共通契約へ統合する。エージェントクライアントはこの有効集合を消費するだけであり、取得経路の選択やプラグイン構造の差異を意識しない。

## 構成と責務

| 主体 | 所有するもの |
|---|---|
| Skillのowner repository | `SKILL.md`、リファレンス文書、テストフィクスチャ、実行スクリプト |
| `flake.nix` | 外部ソースのURLとコミットリビジョンの固定、`pluginSources`への受け渡し |
| `skills/plugins/` | 外部ソースの走査と正規化、共通レジストリ契約への登録 |
| `profiles/workstation.nix` | ホストで有効にするSkill集合の選択 |
| `agents/clients/<id>` | 有効なSkillを各エージェントの配備先（`~/.claude/skills/` 等）へ投影するアダプタ |
| `capabilities` | Skillが必要とする外部ツール、プロバイダ、実行時基盤の契約 |

ツールの操作マニュアルや外部標準の手順は、仕様を決定するowner repository側に置く。中央リポジトリへ本文を手作業で複製すると、変更理由とリビジョンが乖離してメンテナンス負債となるため、外部Skillはソースリポジトリから宣言的に参照する。

依存の方向は次に固定する。外部リポジトリから`dotfiles-wsl`への逆依存、およびCapabilityからSkillやエージェントへの逆依存は作らない。

```text
source:  dotfiles-wsl -> pinned owner repository
runtime: Agent -> Skill -> Capability -> provider/runtime
```

## 外部ソースの登録契約

外部ソースを追加・保守する際は、`flake.nix`で取得したソース実体を`specialArgs.pluginSources`へ渡す。リポジトリ固有のファイル走査と正規化は`skills/plugins/module.nix`が担当する。

外部ソース内の各Skillは、以下の標準契約を満たす必要がある。

- ソースリポジトリのルート直下に`skills/<id>/SKILL.md`の標準配置を持つ。
- Skill IDは安全なkebab-caseで命名されている。
- ソースをまたぐ同一Skill IDが存在せず、名前衝突が排除されている。

## 導入済み外部ソース

現在、以下の 2 つの外部リポジトリからSkillを取り込んでいる。

### Orca
Orcaデスクトップ環境および内蔵ツールの操作手順を提供する。

- `orca-cli`: ワークツリー、端末セッション、内蔵ブラウザの操作。
- `orchestration`: 複数エージェント間の構造化メッセージングとタスク委譲。
- `computer-use`: OSウィンドウおよびデスクトップUIの操作。
- `orca-emulator` / `orca-emulator-android`: モバイルエミュレータ操作。
- `orca-linear` / `linear-tickets`: Linearチケットの取得とPR紐付け。
- `orca-per-workspace-env`: ワークスペース単位の環境設定。

### architecture-standard
ソフトウェア設計およびアーキテクチャ標準の最新規範を参照・適用する。標準本文は手元の配備ツリー（`<standard-root>`）から相対参照で直接読み取り、過去のコミット探索やローカルの固定パスを仮定しない。

- `standard-apply`: 最新の規律（原則、関心事、構造、ツール）に基づき、設計、実装、リファクタリング、レビュー、意味回収を進める入口Skill。
- `standard-conformance`: 静的解析設定やコード境界を最新標準と照合し、差分管理可能なJSON形式で違反を報告する読み取り専用監査Skill。段階的適用の基線（`docs/conformance-baseline.json`）は対象プロジェクト側で管理し単調減少させる。
- `standard-feedback`: 標準適用中に規律の矛盾、不成立、欠落、曖昧さを実測した際、`YukiIto1999/architecture-standard`のGitHub Issueへ改訂提案を還流するSkill。重複起票を防ぐ事前検索を行い、GitHub MCP経由で固定書式の提案を送信する。

## 拒否条件

以下の状態は評価およびビルド検査で拒否される。

- 採用Skillのディレクトリまたは直下の`SKILL.md`が存在しない。
- ソースをまたいで同一のSkill IDが重複している。
- レジストリに存在しないCapabilityを要求している。
- 秘密情報、認証資格情報、またはプライベートな作業記録をSkillソースとしてNix storeへ取り込んでいる。
