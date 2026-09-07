# 外部リポジトリ所有Skillの構成

**読み手:** 外部リポジトリが所有するSkillをこのホストのエージェントへ取り込む設計と契約を理解・保守する人。

外部リポジトリが所有するSkillは、owner repositoryから直接取得する。`dotfiles-wsl`は固定したコミットから採用対象を登録し、`dotfiles.skills.registry`でローカルSkillと単一の共通契約へ統合する。エージェントクライアントはこの有効集合を消費するだけであり、取得経路の選択やプラグイン構造の差異を意識しない。

## 構成と責務

| 主体 | 所有するもの |
|---|---|
| Skillのowner repository | `SKILL.md`、リファレンス文書、テストフィクスチャ、実行スクリプト |
| `flake.nix` | 外部ソースのURLとコミットリビジョンの固定、`pluginSources`への受け渡し |
| `skills/plugins/` | 採用表に基づく外部Skillの登録、source存在確認、同名拒否 |
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

外部ソースを追加・保守する際は、`flake.nix`で取得したソース実体を`specialArgs.pluginSources`へ渡す。`skills/plugins/module.nix`の採用表がsourceごとの実体、採用するSkill ID、および各Skillの`requiresCapabilities` / `requiresSkills`を宣言し、レジストリには採用表に記載したSkillだけを登録する。したがって、upstreamにSkillが追加されても採用表を変更しない限り登録対象は変わらない。

外部ソース内の採用Skillは、以下の標準契約を満たす必要がある。

- 採用表にSkill IDと依存宣言を明記する。
- ソースリポジトリのルート直下に`skills/<id>/SKILL.md`の標準配置を持つ。
- Skill IDは安全なkebab-caseで命名されている。
- ソースをまたぐ同一Skill IDが存在せず、名前衝突が排除されている。

## 導入済み外部ソース

現在、以下の2つの外部リポジトリからSkillを取り込んでいる。採用するSkillの集合と依存宣言は、[`skills/plugins/module.nix`](../../skills/plugins/module.nix)の採用表を唯一の正本とする。

### Orca
Orcaデスクトップ環境および内蔵ツールの操作手順を提供する。採用対象と依存宣言は採用表で管理する。`linear-tickets`は`orca-linear`のlegacy aliasであり、同じ判断を二つのSkillが所有してroutingが割れるため採用しない。

### architecture-standard
ソフトウェア設計およびアーキテクチャ標準の最新規範を参照・適用する。標準本文は手元の配備ツリー（`<standard-root>`）から相対参照で直接読み取り、過去のコミット探索やローカルの固定パスを仮定しない。採用対象と依存宣言は採用表で管理し、`standard-feedback`だけが`github-resources`を要求する。

## 拒否条件

以下の状態は評価およびビルド検査で拒否される。

- 採用Skillのディレクトリまたは直下の`SKILL.md`が存在しない。
- ソースをまたいで同一のSkill IDが重複している。
- レジストリに存在しないCapabilityを要求している。
- 秘密情報、認証資格情報、またはプライベートな作業記録をSkillソースとしてNix storeへ取り込んでいる。
