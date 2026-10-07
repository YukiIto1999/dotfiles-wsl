# ツール構成

**読み手:** 正本の場所と現在値の取り方を調べたい人。作業中に読む。

この文書は、導入しているツールとserviceの正本、現在値の取り方、実行入口の制約を示す。
現在値のrosterは評価結果から取り、外部CLIでは固定sourceと実行互換性に必要な版を記す。

## CLI

| 区分 | 正本 | 現在の値 |
|---|---|---|
| system package | [`workstation/module.nix`](../../workstation/module.nix)と各ownerの`environment.systemPackages` | `nix eval --json .#nixosConfigurations.nixos.config.environment.systemPackages --apply 'map (p: p.name)'` |
| 汎用ツール | [`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.packages`。devenvとactrunは[`flake.nix`](../../flake.nix)で固定した公式release inputから選ぶ | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.packages --apply 'map (p: p.name)'` |
| Home Manager program | [`workstation/home/module.nix`](../../workstation/home/module.nix)の`programs`。Atuinは同期なしのローカル履歴 | 同じunitを参照する |
| language server | [`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.lsp` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.toolchain.lsp --apply builtins.attrNames` |
| 保守用devShell | [`flake.nix`](../../flake.nix)の`devShells` | `nix develop --command echo`の後に`$PATH`を確認する |

`nixfmt`はeditorと単一file、`nixfmt-tree`は`nix fmt`とrepository全体の検査を担当する。[Nixfmt README](https://github.com/NixOS/nixfmt/blob/master/README.md)

## 外部CLI

外部CLIの採用は[`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.packages`が所有する。
決定的な操作はCLIを直接使い、候補や証拠の意味判断が必要な場合だけ該当Skillを使うため、一commandのための新しいSkillは置かない。
以下はsourceの構成と利用契約であり、この文書を更新しただけで配備や全用途の実行を確認したことにはならない。

### Explainer

raw sourceは[`explainerSkills`](../../flake.nix)の[`578defba7249fde5366689424ed6017f76b5598b`](https://github.com/mizchi/explainer/tree/578defba7249fde5366689424ed6017f76b5598b)であり、registryは`skills/explainer`、`skills/explainer-book`、`skills/first-reader`を直接参照する。
runtimeの正本は[`package.nix`](../../toolchain/package/explainer/package.nix)、[`package.json`](../../toolchain/package/explainer/package.json)、[`package-lock.json`](../../toolchain/package/explainer/package-lock.json)である。
upstream scriptは変更せず、runtime用manifestとlockだけを置き換え、Node 24、Playwright `1.61.1`に対応するChrome headless shell `149.0.7827.55`、`@mizchi/vlmkit` `0.22.0`を固定する。
これは既存のbrowser MCPのpageやsessionへ接続する経路ではなく、CLI自身が使うbrowser runtimeである。

| 入口 | 第1引数 | upstream script |
|---|---|---|
| `explainer-build-html` | Markdown fileの絶対path。複数ページは後続引数へ渡す | `skills/explainer/scripts/build-html.mjs` |
| `explainer-verify-doc` | 文書directoryの絶対path | `skills/explainer/scripts/verify-doc.mjs` |
| `explainer-verify-book` | book directoryの絶対path | `skills/explainer-book/scripts/verify-book.mjs` |
| `explainer-figure-check` | 図fileの絶対path | `skills/explainer/scripts/figure-check.mjs` |
| `explainer-vlmkit` | 原版CLIのsubcommand | `node_modules/@mizchi/vlmkit/dist/vlmkit.mjs` |

最初の四wrapperは相対pathをexit 2で拒否し、呼出しごとに`${TMPDIR:-/tmp}/explainer-runtime.XXXXXX`へ書込み可能なCWDを作って、管理下の`package.json`と`node_modules`だけをsymlinkする。
生成されたreportは出力に示された一時directoryのpathから取得し、必要な証拠を保持した後の回収はsession lifecycleまたは実行ownerが行う。
wrapper自身が終了直後にreportを削除するとは扱わない。

[`verify-doc.mjs`](https://github.com/mizchi/explainer/blob/578defba7249fde5366689424ed6017f76b5598b/skills/explainer/scripts/verify-doc.mjs#L31-L46)は文書directoryから最も近い祖先の`package.json`を探し、見つからない場合だけCWDをdependency rootにする。
管理runtimeを使う文書は、projectのpackage内やその配下ではなく、祖先にprojectの`package.json`がなく、project依存を要求しない専用のstandalone directoryへ置く。
wrapperのCWD変更や`NODE_PATH`だけでは、祖先packageが選ばれる挙動を上書きしない。
記事と`checks.json`を先に読み、任意shellと書込み、外部通信を許可範囲へ照合し、standalone directoryを安全なsandboxとは呼ばない。
図とHTMLは出力を開いて読んだ範囲を証拠にし、checkerの合格だけで実画面受入やa11y全適合としない。

[`checks`のloop](https://github.com/mizchi/explainer/blob/578defba7249fde5366689424ed6017f76b5598b/skills/explainer/scripts/verify-doc.mjs#L46-L75)はsubprocessのexitを捨て、stdoutとstderrを結合した出力を照合する。
既知の非zero subprocessでも`VERIFIED`になるため、wrapperのexit 0と`VERIFIED`だけを実行成功の証明にせず、custom `tech-article-reproducibility`がcommandごとのexit、個別stream、到達stateを記事の期待と照合する。
optional D2、TALA、ELK、TLC、Apalacheなどのbackendはこのpackageで供給せず、実行に必要なら別の許可済み前提として扱う。
`first-reader`はraw source内のPython 3 stdlib scriptを使い、模擬readerやrecall-from-logを実command再現や実際の翌日の人間の記憶測定へ置き換えない。

### Similarity

[`similarity.nix`](../../toolchain/package/similarity.nix)は[公式release v0.5.0](https://github.com/mizchi/similarity/releases/tag/v0.5.0)のhash固定archiveから、`similarity-ts`、`similarity-rs`、`similarity-generic`の原版binaryを供給する。
現packageの対象は`x86_64-linux`であり、他言語のCLIやSDK、MCP providerを提供する構成ではない。

| 対象 | 入口 |
|---|---|
| TypeScript / JavaScript | `similarity-ts <path>` |
| Rust | `similarity-rs <path>` |
| C# | `similarity-generic --language csharp <path>` |

結果は構造の似た候補であり、型、API、用途、変更理由、振る舞いの等価性や共通化の正当性は元のsourceとcallerから判断する。
候補ゼロを重複なしの証明にせず、通常のTypeScriptでもfalse negativeがあり得る。
JSX / TSXの受理をReact componentやmarkupの堅牢な比較と同一視せず、検出されなかったJSXの重複を既知の制約として扱う。
言語ごとの実装差、比較treeへの縮約、parse errorの扱いは[一次sourceに基づく調査対象](https://github.com/mizchi/similarity/blob/8fa7879ac88e80f2c98c00e331f8ad19aa1a33bc/crates/core/src/function_extractor.rs#L440-L468)であり、調査したmainのSHAを配備releaseと同一視しない。
自動共通化やmerge gateには使わず、実際の引数は各binaryの`--help`を読む。

### Actrun

`actrun`は既に[`flake.nix`](../../flake.nix)で固定したsourceから管理するCLIであり、今回新しいCI Skillやtask定義の正本を作るものではない。
対象workflowの変更、local実行の依頼、互換性の調査がある場合だけ、実際のworkflowを入力にしてlintとplanを取る。

```sh
actrun lint .github/workflows/ci.yml
actrun workflow run .github/workflows/ci.yml --dry-run
```

引数の根拠は[採用revisionのREADME](https://github.com/mizchi/actrun/blob/1db9aff5b364de6eacda68e3f2ce2238f9992272/README.md#L110-L118)と[linterの入口](https://github.com/mizchi/actrun/blob/1db9aff5b364de6eacda68e3f2ce2238f9992272/README.md#L215-L220)に置く。
lint、dry-run、許可されたlocal実行、remote CIの結果は別の証拠であり、localでの成功をGitHub runner、token権限、OIDC、publicationの成功としない。
実行前にeventと条件分岐、`uses`で取得するaction、実行trust、書込みとnetwork、secretの出典と受渡し範囲を確認する。
原版の[secretのmasking](https://github.com/mizchi/actrun/blob/1db9aff5b364de6eacda68e3f2ce2238f9992272/README.md#L463-L480)は外部送信を防ぐ保証ではなく、worktreeや一時directoryもsecurity sandboxではない。
実runは許可された対象と副作用だけで行い、dry-runから秘密情報の利用や第三者actionへの全trustを推定しない。


## 運用command

利用者向けの入口は`dotfiles-`prefixを持つ生成commandである。[`platform/cli/module.nix`](../../platform/cli/module.nix)は`dotfiles.platform.cli.commands` optionとsystem package登録を持ち、各owner moduleは[`platform/cli/impl/mk-command.nix`](../../platform/cli/impl/mk-command.nix)を明示的にimportする。`packages`にないhost固有commandをcheckoutから呼ぶときは、対象hostの`nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.<name>`を直接指定する。

containerを有効にしたhostのimage同期は次のpathで実行する。

```bash
nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages -- --status
nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages
```

現在の一覧は`nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.cli.commands --apply builtins.attrNames`で確認する。

## Agent、Skill、Capability

[`profiles/workstation.nix`](../../profiles/workstation.nix)が共有するAgent client、Capability、language server、identityを選び、`profiles/hosts/<host-id>.nix`がhost固有の値と選択を持つ。
Skill、provider、backendはCapabilityから導出し、profileに直接列挙しない。

| 区分 | 正本 | 現在の値 |
|---|---|---|
| Agent adapter | [`agents/clients/`](../../agents/clients)が`dotfiles.agents.registry`へ登録し、`enabled`から採用済み`clients`を導く | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.clients --apply builtins.attrNames` |
| Client installer | 各clientの`install` contractと[`agents/impl/install-agents.sh`](../../agents/impl/install-agents.sh) | `nix run .#dotfiles-install-agents -- --print-manifest` |
| Agent runtime | [`agents/module.nix`](../../agents/module.nix)、[`agents/impl/runtime/`](../../agents/impl/runtime) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.runtime` |
| 静的subagent | `agents/subagents/` | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.file --apply 'f: builtins.filter (n: builtins.match "\\.claude/agents/.*" n != null) (builtins.attrNames f)'` |
| local Skill | [`skills/`](../../skills) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.skills.enabled` |
| Capability | [`capabilities/`](../../capabilities)の`dotfiles.capabilities.registry`とprofileの選択 | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.capabilities.resolved` |
| plugin Skill | [`flake.nix`](../../flake.nix)のplugin inputと[`flake.lock`](../../flake.lock) | clientごとの生成設定を参照する |

専門判断の導線は`Agent -> Skill`、配備するproviderの導線は`Capability -> provider/runtime`であり、harness primitiveとmanaged CLIは直接使う。
Skill-firstはtask routingの規則であり、providerをSkill配下へ置くという意味ではない。

## Runtime observation

| 区分 | 正本 | 現在の値 |
|---|---|---|
| observationの型 | [`health/module.nix`](../../health/module.nix)のclosed union | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.health.observations --apply 'xs: builtins.mapAttrs (_: x: x.kind) xs'` |
| 検査対象と値 | 各ownerが`dotfiles.health.observations`へ登録 | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.health.observations --apply builtins.attrNames` |
| 汎用runner | [`health/module.nix`](../../health/module.nix)、[`health/impl/doctor.sh`](../../health/impl/doctor.sh)、[`health/impl/probe.sh`](../../health/impl/probe.sh) | `dotfiles-doctor --json` |
| MCP protocol | [`platform/mcp/gateway/module.nix`](../../platform/mcp/gateway/module.nix)とそのobserver | registryの`mcp/protocol/<gateway-id>` |

owner moduleは意味と観測値を持ち、`health`は型、実行、集約だけを持つ。対象を増減するときにdoctor独自のinventoryは更新しない。

## MCPとcontainer

| 区分 | 正本 | 現在の値 |
|---|---|---|
| gateway | [`platform/mcp/gateway/module.nix`](../../platform/mcp/gateway/module.nix)の`dotfiles.platform.mcp.gateway` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.gateway --apply 'g: builtins.removeAttrs g [ "source" ]'` |
| MCP target | Capability実装が登録する`dotfiles.platform.mcp.targets` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.targets --apply builtins.attrNames` |
| Docker backend | [`platform/containers/module.nix`](../../platform/containers/module.nix)のcontractと各Capability実装 | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.containers.services --apply builtins.attrNames` |
| MCP front | [`platform/mcp/module.nix`](../../platform/mcp/module.nix)がtargetから導く`dotfiles.platform.mcp.fronts` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.fronts`。稼働は`systemctl status mcp-front-<name>` |
| telemetry | [`telemetry/module.nix`](../../telemetry/module.nix) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.telemetry` |

MCP targetはprovider、executable、transport、lifecycle、port、backend unit、probeを持つ。generic Platformはprovider IDとapplication IDを列挙せず、Capability実装から登録値を受ける。公開agentgatewayは全frontを一つのURLへ束ねるが、front serviceの起動依存は持たない。credential、container、host processの境界は[セキュリティ設計](../architecture/security.md)を参照する。

構成を変更するときは[変更箇所](change-map.md)で正本を特定し、適用後に`dotfiles-doctor`で宣言と実状態の収束を確認する。
