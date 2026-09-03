# Repository所有Skillのcomposition

**読み手:** 外部repositoryが所有するSkillを、このhostのAgentへ取り込む設計・実装を担当する人。変更前に読む。

この文書は外部repository所有Skillの将来設計を定める。現行のlocal SkillとOpenAI security pluginはすでに[`skills/`](../../skills)のregistryへ統合済みである。外部repositoryが所有する手順、domain contract、private dataの形式はここでは設計しない。

## 決定

外部repositoryが所有するSkillはowner repositoryから直接取得する。`dotfiles-wsl`は固定したrevisionから採用対象だけを登録し、`dotfiles.skills.registry`でlocal Skillと合成する。Agent clientは有効なSkill集合を消費するだけで、sourceの選択やSkill依存を所有しない。

| Owner | 所有するもの |
|---|---|
| Skillのowner repository | `SKILL.md`、reference、script、eval、Skill固有commandの公開手段 |
| `flake.nix` | private dataを含まないsourceとrevisionの固定、`pluginSources`への受け渡し |
| `skills` | sourceの正規化、registry、Skill依存、Capability依存、重複と欠落の拒否 |
| `profiles/workstation.nix` | このhostで有効にするSkill集合 |
| `agents/clients/<id>` | 有効なSkillを各clientのdestinationへ投影するadapter |
| `capabilities` | Skillが必要とするconsumer非依存のcommand、provider、runtime contract |

Skillはdomainの判断と一緒に変更されるため、owner repositoryに置く。中央repositoryへ複製すると、本文、reference、evalの変更理由とrevisionがownerから分かれる。donorを参考に`dotfiles-wsl`が別のSkillを所有し直す場合だけlocal Skillとする。

依存方向は次に固定する。

```text
source:  dotfiles-wsl -> pinned owner repository
runtime: Agent -> Skill -> Capability -> provider/runtime
```

owner repositoryから`dotfiles-wsl`への逆依存、CapabilityからSkillまたはAgentへの逆依存は作らない。

## 現行contract

local Skillは`skills/<id>/module.nix`が次のcontractを登録する。

```nix
config.dotfiles.skills.registry.<id> = {
  source = ./skill;
  requiresSkills = [ ];
  requiresCapabilities = [ ];
};
```

[`skills/module.nix`](../../skills/module.nix)はID、`SKILL.md`の存在、依存先、依存の重複、有効集合のclosureを検査する。[`capabilities/module.nix`](../../capabilities/module.nix)はSkillが要求したCapabilityの存在と有効化を検査する。[`profiles/workstation.nix`](../../profiles/workstation.nix)はregistryのkeyを有効集合として選ぶ。

OpenAI security pluginは[`skills/plugins/module.nix`](../../skills/plugins/module.nix)が固定source内の`skills/`をregistryへ投影し、複数plugin間の同名Skillを拒否する。plugin sourceの追加やrevision更新では、upstreamが追加したSkillも有効集合へ入るため、lock更新とSkill rosterのreviewを同じ変更で行う。

全clientへの共通配備は維持する。sourceごとのclient選択は、必要性が実証されていないため導入しない。

## 外部sourceの追加contract

外部sourceを追加するときは、`flake.nix`が取得したsourceだけを`specialArgs.pluginSources`へ渡す。repository固有のlayout、採用Skill、依存は`flake.nix`へ置かず、`skills`配下のsource adapterが正規化する。

adapterは各採用Skillについて次を確定する。

- 安全なkebab-caseのSkill ID
- `SKILL.md`を含むimmutableなsource directory
- 合成する別SkillのID
- 必要なsemantic Capability ID
- sourceをまたぐ同名Skillの不在

同名Skillに優先順位、alias、overrideは設けず、重複を拒否する。frontmatterの`name`はSkill IDと一致させる。

## Runtime command

Skill固有commandを直接Skill registryのfieldとして増やさない。人や複数Agentから利用できる機能ならsemantic Capabilityとして所有し、provider package、runtime executable、backendをそのCapabilityへ置く。Skillは`requiresCapabilities`でそのIDだけを要求する。

`git`やrepository標準の基礎commandはCapabilityとして重複登録しない。特定Skillにしか意味がなく、独立したruntime lifecycleも持たないscriptはSkillの`skill/scripts/`へ置く。

wrapperに埋め込めるのはNix storeから読まれてよい非秘密値だけである。secretや非公開pathをderivationへ束縛しない。実行時secretは対応するCapabilityがSOPS境界から受け取り、Skill sourceへcredential fieldを追加しない。

## 拒否する構成

evaluationとbuild checkは次を拒否する。

- Skill ID、Capability ID、依存IDが安全なkebab-caseでない
- 採用Skillのdirectoryまたは直下の`SKILL.md`がない
- registryにないSkillまたはCapabilityを要求する
- 有効なSkillが無効なSkillまたはCapabilityを要求する
- `requiresSkills`または`requiresCapabilities`に重複がある
- sourceをまたいでSkill IDが重複する
- CapabilityがAgentまたはSkillを参照する
- provider/backendをprofileが直接選ぶ
- secret、mutable state、private recordをSkill sourceとしてNix storeへ取り込む

## Admission

repositoryがSkillを所有しているだけでは配備しない。次をすべて満たしたsourceとSkillだけをregistryへ加える。

1. source全体にprivate record、evidence、credentialがなく、Nix storeへ取り込めることを人が確認する。
2. 上流Skillの直接採用が[Skill portfolio](skills.md)のsignature procedure規則を満たす。local Skillへの再構成が規範やroutingの複製になる場合だけ直接採用する。
3. licenseと利用条件を確認する。
4. Skillが必要とするruntime機能を既存Capabilityで表せるか確認する。新しいCapabilityはconsumer非依存の意味とlifecycleがある場合だけ作る。
5. owner evalに加え、実際の全client配備集合でtrigger、near-miss、欠ける依存、immutable sourceを検査する。
6. SkillがGit objectやrepository metadataを必要とする場合、固定source artifactがその操作を実行できる。

Nixのtypeやclosure checkは、sourceがprivate dataを含まないことを意味から証明できない。`pluginSources`への登録はreviewが必要なtrust decisionである。非公開pathはruntimeのstore外設定で扱う。

## 保留中のsource

### architecture-standard

`standard-apply`は標準本文とprocess mappingから分離すると価値を失うsignature procedureなのでglobal配備候補になる。ただし、対象projectのADRが指すGit commit objectを読むため、通常の`flake = false` source treeだけでは必要なobjectを持たない。

ownerがprivate dataを含まない固定可能な配布artifactを用意し、記録済みcommitを解決できるようにするか、同等のimmutable snapshot contractへ上流Skillを変更するまでadmissionを保留する。確認した範囲ではowner rootに`LICENSE`または`COPYING`もなく、利用条件の確定が必要である。

### vibe-knowledge

private recordを含むrepository自体をinputにしない。owner側にprivate dataを含まないSkill配布sourceと、必要なら同じpinから作るCapability実装ができた後でadmissionを行う。

## 検証と導入

新しいsourceの導入では次を同じ変更に含める。

- flake inputと`flake.lock`
- `skills`配下のsource adapterとregistry contract
- 必要なSkill/Capability dependency
- 全clientの配備projection
- trigger、near-miss、依存欠落、重複を検出するcheck
- [Skill portfolio](skills.md)のprovenanceと採用理由

`architecture-standard`と`vibe-knowledge`は現時点で加えない。revision更新ではupstreamの追加、削除、renameを暗黙の変更として扱わず、最終registryと配備結果を確認する。
