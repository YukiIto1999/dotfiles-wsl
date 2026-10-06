# 外部リポジトリ所有Skillの構成

**読み手:** 外部Skillの登録と供給元の差替を保守する人が、作業中に契約を参照する。

外部Skillもlocal Skillも、`dotfiles.skills.registry`の一つのentryとして登録する。
clientは`dotfiles.skills.enabled`から選んだentryのsourceを配備するだけであり、供給元ごとのregistryや取得処理を持たない。
Skillのsourceは固定したrepositoryから直接参照し、本文や資材を`skills/<id>/skill/`へ手作業で複製しない。

## 所有

| 主体 | 所有するもの |
|---|---|
| Skillのowner repository | `SKILL.md`、reference、script、同梱資材 |
| `flake.nix`と`flake.lock` | 外部sourceの取得先とrevisionの固定、`specialArgs.pluginSources`への受け渡し |
| 採用を宣言するNix module | 採用ID、source directory、`requiresCapabilities`、`requiresSkills` |
| `skills/plugins/module.nix` | 既存pluginの採用表と、表内のID衝突の拒否 |
| `skills/module.nix` | 最終registryのsourceと依存の検査、配備可能なSkill集合の導出 |
| `agents/clients/<id>` | 有効なSkillを各clientの配備先へ投影するadapter |
| `capabilities` | Skillが必要とする外部tool、provider、実行時基盤の契約 |

依存metadataはupstreamの本文から自動生成せず、取込側のNix module ownerが本文、reference、scriptを読んで宣言する。
上流がmetadataを持たないことは、依存がない根拠にはならない。
空の依存listも、取込側が確認した宣言であり、未指定時のdefaultではない。
sourceの更新や差替では、本文と資材だけでなくこの宣言も見直す。

```text
source:  dotfiles-wsl -> pinned owner repository
runtime: Agent -> Skill -> Capability -> provider/runtime
```

## 登録契約

| Field | 契約 |
|---|---|
| registry key | 安全なkebab-caseのSkill ID |
| `source` | 直下に通常fileの`SKILL.md`があるdirectoryへのNix path |
| `requiresCapabilities` | 取込ownerが宣言する既知のCapability IDのlist。明示必須 |
| `requiresSkills` | 取込ownerが宣言する既知のSkill IDのlist。明示必須 |
| `enabled` | resolved Capabilityと推移的なSkill依存を満たすIDから導くread-onlyの一覧 |

`SKILL.md`のfrontmatterにはregistry IDと一致する`name`と、空でない`description`が必要である。
sourceのdirectory名やupstreamでの配置は自由であり、全repositoryに`skills/<id>/`を要求しない。
source directoryを直接渡すため、同梱のreferenceやscriptもそのまま使え、本文を変換するadapterは不要である。
repository内の別directoryを相対参照するSkillでは、その参照先を含む固定sourceを保ち、Skill directoryだけを切り出さない。

同じ優先度で同IDのsourceを複数moduleが宣言すると、同じpathを指定していてもNix optionのmergeが失敗する。
暗黙の後勝ちや同名aliasを使わず、意図した差替には既存の`lib.mkForce`を使う。
同じ優先度の差替が二つある場合も拒否する。

## 外部sourceの追加

1. upstreamの採用するrevisionとlicenseを確認し、固定したflake inputを`flake.nix`と`flake.lock`で宣言する。
2. そのsource実体を`specialArgs.pluginSources`へ渡し、`SKILL.md`と必要な資材があるdirectoryを選ぶ。
3. 取込を所有するmoduleで、採用IDの`dotfiles.skills.registry`にsourceと二つの依存listを明示する。
4. 同IDが既にある場合は、別entryを追加せず次節の差替として扱う。

既存pluginの追加採用は[`skills/plugins/module.nix`](../../skills/plugins/module.nix)の採用表を変更する。
この表が使う`skills/<id>/`は既存sourceの配置であり、registryの共通要件ではない。
upstreamにSkillが増えても、採用moduleが登録するまで配備対象にはならない。
Skill登録時の自動download、更新時の無固定取得、新しいsource registryは導入しない。
sourceをNix storeへ取り込む前に、秘密情報、認証資格情報、非公開の作業記録が含まれないことを取込ownerが確認する。
その内容検査をsource存在確認で代替せず、自動検出されるともみなさない。

## 同IDの差替

差替先の固定sourceとfrontmatterのIDを確認し、取込ownerが依存宣言を見直してから、採用するmoduleでentry全体を`lib.mkForce`にする。
entry全体を置き換えると、旧sourceの依存listが差替先へ暗黙に残らない。
clientやroutingが使うIDは維持され、本文と資材の供給元だけを交換できる。

次のmoduleは、同梱fixtureを使ってlocalの`bug-analysis`を同IDの別sourceへ差し替える再現例である。
空の依存listはこのfixtureの宣言であり、実際の上流Skillについて依存がないと主張する例ではない。
例の相対pathは`profiles/hosts/`のhost moduleへ書く場合の指定である。

```nix
{ lib, ... }: {
  dotfiles.skills.registry.bug-analysis = lib.mkForce {
    source = ../../skills/fixtures/external-source/procedures/bug-analysis;
    requiresCapabilities = [ ];
    requiresSkills = [ ];
  };
}
```

実際の差替では、このsourceを固定したupstreamのSkill directoryへ置き換え、確認した依存listを同じentryへ宣言する。
依存契約を変えないと取込ownerが確認した場合は、entryの`source`だけを`lib.mkForce`で置き換えることもできる。
たとえばlocalの`grilling`を元の外部Skillへ戻す場合は、固定したMatt Pocock repositoryの`skills/productivity/grilling/`をsourceに選び、licenseと本文、依存を見直す。
上流のnameが異なる場合は本文を書き換えて同IDを装わず、ID変更に伴うcallerとroutingの変更として扱う。
元に戻すときは差替定義を取り除くか、元の採用moduleが指すsourceへ明示的に戻す。
外部Skillへの恒久切替で旧local本文が不要になった場合は、旧登録と本文を削除し、同IDの配備経路を二つ残さない。

## 現在のplugin

採用するSkillと依存宣言の正本は[`skills/plugins/module.nix`](../../skills/plugins/module.nix)であり、Orcaとarchitecture-standardの固定sourceを使う。
Orcaのlegacy aliasである`linear-tickets`は`orca-linear`とroutingを分けるため採用しない。
architecture-standardの規範本文は配備済みsourceから読み、`standard-feedback`は`github-resources`を要求する。

architecture-standardの運用Skillは、同repositoryの`skills/<id>/`を正本とし、`standard-update`と`standard-audit`も既存の採用表から配備する。
clientごとの`.claude/skills/`などはadapterの投影先であり、正本の所有先ではない。
`standard-update`は最後のscoped auditに`standard-audit`を、外部Web調査に`web-research`を使うため、この二つをSkill依存として宣言する。
同梱のClaude Code専用evaluatorは任意のconsumerであり、通常のSkill利用のCapability要件にはしない。
別repositoryから標準を変えるときは、`environment-design`から作業checkoutの`skills/standard-update/SKILL.md`へ渡し、配備済みsourceを編集しない。

## 検査

[`skills/checks.nix`](../../skills/checks.nix)の`skill-source-contract`は、外部sourceの直接採用、同IDのentry差替、依存metadataの切替、client共有sourceへの反映、referenceとscriptの利用を検査する。
不存在source、fileをsourceにした指定、directoryの`SKILL.md`、不正ID、未知の依存、metadata未指定、無指定の同ID衝突、競合する差替も拒否する。
frontmatterとIDの不一致は、このcheckと`skill-frontmatter-contract`が検査する。
sourceの検査は優先度を解決した最終registryに対して行い、不採用になった旧sourceを別経路で検査しない。

```sh
nix build .#checks.x86_64-linux.skill-source-contract \
  .#checks.x86_64-linux.skill-frontmatter-contract \
  .#checks.x86_64-linux.skill-capability-gating
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.skills.enabled
```

