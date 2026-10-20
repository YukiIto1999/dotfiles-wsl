# AI tooling

**読み手:** Agent、Skill、Capability、provider、runtimeの境界を変更する人。

AI CLIのbinary、共通資材、Capability実装、MCP接続は別のlifecycleを持つ。binaryは供給元が提供するNix packageで、client別のnative Nix profileの世代として更新される。policy、Skill、subagent、managed config、MCP serviceはNixOS generationが宣言し、system generationとclient profileは別の正本と別のrollback対象である。

## 配備と呼出し

```text
agents/policy/AGENTS.md ───────────────────┐
agents/subagents/*.md ── client変換 ──────────┤
skills/*/skill/ ──────────────────────────┼─► Nix store ─► 各clientの設定領域
Orca / architecture-standard / Matt / Google / .NET / mizchi explainerの固定source ─┘

Agent ─► Skill ─► Capability ─► provider adapter ─► Platform MCP ─► gateway
                         └────► backend / credential / persistent state
                         └────► managed CLI runtime ─► 必要時だけ起動するsandbox

Agent ─► harness primitive / managed CLI ─► toolchain runtime

AI CLI ─► LSP ─► language server
       └► OTLP ─► telemetry collector
```

[`agents/subagents/routing.nix`](../../agents/subagents/routing.nix)はsubagentからSkillへのroutingとsubagent間handoffだけを持ち、provider名、backend名、直接provider例外は置かない。
Skillの依存は取込ownerのNix moduleが`requiresSkills`と`requiresCapabilities`で宣言し、条件付きCapability入口は`optionalCapabilities`へ分ける。
外部Skillでは[`skills/plugins/module.nix`](../../skills/plugins/module.nix)がこのmetadataを所有する。

専門判断が必要なtaskは`Agent → Skill`で方法を選び、配備するproviderは`Capability → provider/runtime`の公開契約を通す。
Agentはtask、権限、委譲、成果物handoffを所有する。
Skillは反復する判断、手順、停止条件を所有し、primitive操作のたびに起動するwrapperにはしない。
Capabilityはconsumerに依存しない機能contractである。
provider adapter、container、database、credential、stateはCapabilityの実装詳細であり、AgentやSkillへ逆依存しない。

Read、Grep、Glob、Edit、Write、Bash、LSP、subagentのようなharness機能と、決定的な操作を担うmanaged CLIはAgentが直接使う。
repositoryに配備するproviderは次のCapabilityを通し、公開契約を確認せず内部processやcontainerへ接続しない。

Capability実装の正本は各`capabilities/<id>/module.nix`にあり、Task入口はlocalまたはpluginの採用moduleが宣言する。
`requiresCapabilities`はSkill全体の必須依存として配備をゲートし、`optionalCapabilities`は該当branchだけの入口として扱う。
policyのCapability対応には両方を記載し、任意Capabilityの未選択で一般Skill全体を配備から外さない。
現在のCapability IDは次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.capabilities.registry --apply builtins.attrNames
```

各Skillが宣言するCapabilityは次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.skills.registry --apply 'builtins.mapAttrs (_: skill: { inherit (skill) requiresCapabilities optionalCapabilities; })'
```

Skill-firstはrouting規則であり、MCPやcontainerをSkill directoryへ置く規則ではない。選択したSkill本文はclientへ配備する一方、Capability実装はtransport、service lifecycle、network、credential、永続dataを所有するため、`capabilities/`に置く。

`security-assessment`は[`Strix runtime`](../../capabilities/security-assessment/strix/runtime/module.nix)を通し、`security-review`と既存のsecurity subagentから、許可された隔離対象でのruntime evidenceが必要な場合だけ使う。
MCP endpointや常駐backendを追加せず、CLIは共通の`platform/cli`、sandbox imageの同期は共通の`platform/containers`が所有する。
実行の許可、予算、結果の検証、所有するrunの回収は[Skillの利用契約](../../skills/security-review/skill/references/strix-runtime.md)に従う。

`code-quality`は[SonarQubeの契約](../reference/code-quality.md)を通し、保存済みissueとquality gate、新規scanの出典を提供する。
取得と現在sourceへの適用判断は同名Skill、通常の二軸reviewは原版`code-review`のcallerが所有する。
callerが証拠bundleをaxis briefへ渡すため、read-only reviewerへbackend権限を追加しない。
Git revisionの一致だけで結果を捨てず、逆に保存済みのgateを現在の合格へ読み替えない。

## Profileとregistry

[`profiles/workstation.nix`](../../profiles/workstation.nix)は全host共通のAgent client、Capability、language server、identityを選び、[`profiles/hosts/`](../../profiles/hosts)はhost固有のCapabilityをsemantic IDで加える。MCP providerやcontainer backendはprofileへ直接列挙しない。
共通profileはheap-diagnosticsも選び、provider名の`memlab`ではなく意味上のCapabilityから採用する。

各client adapterは`dotfiles.agents.registry`へ登録し、profileの`enabled`から採用済みの`clients`を導く。
配備、binary供給、runtime wrapper、health、policyの能力表は採用集合だけを読む。

[`skills/module.nix`](../../skills/module.nix)はSkill ID、Skill依存、hard Capability依存から、選択したCapabilityで実行できるSkillを導く。[`capabilities/module.nix`](../../capabilities/module.nix)はCapability依存closure、provider owner、backend ownerを検証し、`dotfiles.capabilities.resolved`、`dotfiles.platform.mcp.enabledProviders`、`dotfiles.platform.containers.enabled`を導く。現在のconsumer数はownershipの判断に使わない。
hard依存は主要手順の必須条件であり、条件付きbrowserやcloud branchで一般Skill全体をgateしない。

Agent clientへ配るのは、解決したSkill registryの`source` directoryとその本文、reference、scriptである。
必要なSkillを失ったsubagentとそのhandoffも配備しない。
Nix module、依存metadata、fixtureは配備先へ混ぜず、同じIDのsource差替えはNixの明示的なoverrideだけで行う。
Orca、architecture-standard、Matt Pocock、Chrome DevTools MCP、.NET skills、mizchi explainerは固定source内の任意のSkill directoryを直接参照し、本文や資材を変換、複製しない。
原版の起動flagも保持し、policy rosterがtask一致、明示command、consumerから読むreference-onlyを区別する。
`user-invocable: false`と`disable-model-invocation: true`が両方あるhelperは、enabled registryに残して依存を満たすが、shared discovery source、clientのnamed Skill directory、subagent routeへは投影しない。
consumerはpolicy rosterのraw source絶対pathを`Read`で開き、固定source実体のsibling referenceを利用する。
architecture-standardの規範本文は、配備済みsourceからでなく、policyが案内する現行規範root（`dotfiles.agents.runtime.standardRoot`）から読む。
同梱のreferenceとscriptは成功してReadした`SKILL.md`の実体のdirectoryから、規範文書のlinkは現行規範rootから解決する。
配備済みsourceの標準本文、Git revision、`flake.lock`は実行packageの出典であり、現行規範の根拠にしない。
`flake.lock`は`dotfiles-rebuild`が最新へ更新して配備したrevisionの記録であり、版を固定して更新を待つ仕組みではない。
片方だけを持つ明示commandなどのnative投影は変えず、原版の起動flagを保持する。
Modern Web Guidanceは外部source全体のhome assetとして保持し、対象guideを原文で読むが、全frontendへ起動するwrapperはSkill registryに採らない。
外部Skillのraw directoryを配ることと、同梱scriptの実行依存を供給することは別の契約である。
explainerのraw sourceとsibling配置はそのまま保持し、別ownerの[`toolchain/package/explainer/package.nix`](../../toolchain/package/explainer/package.nix)が固定したmanifestとlock、browser、絶対pathを要求する実行wrapperを供給する。
package作成時に置き換えるのはruntime用manifestとlockだけであり、upstreamのSkill本文やscriptは変更しない。
wrapperは書込み可能な一時CWDへ管理下のpackageと依存を参照させるが、upstreamが記事側の祖先packageを優先する条件やcheckerの限界を消さないため、対象directoryと証拠の制約は[外部CLI](../reference/tooling.md#外部cli)へ集約する。
任意shell、外部送信、model課金の許可や、optional D2とformal backendの供給をraw採用から推定しない。
`description-writing`とcustom `article-reproduction`は単独で成立する判断を持ち、raw `explainer`、`first-reader`、browserや.NET実行への引渡しを該当branchだけで行う。
これらを一般の執筆やcodingのhard依存へ広げず、返却証拠から同じownerの仕事を再開し、writer側の再現性loopやreader試行を重ねない。
採用IDとpath、revision、licenseの関係は[Skill portfolio](skills.md#直接採用)、登録と差替の契約は[外部リポジトリ所有Skillの構成](repository-skills.md)を参照する。

## Client binary

client binaryの供給元は[llm-agents.nix](https://github.com/numtide/llm-agents.nix)で、`flake.lock`が初回構築用のbaselineと供給元の採用を固定する。供給元の package は provider 自身の固定 nixpkgs と Bun で build され、host の stable nixpkgs へ follows させない。「供給元が package 化した最新版」の日次取得は利用者が承認した鮮度であり、製品の最新 release との一致や供給元 HEAD の取得成功を同一視しない。

client ごとの供給契約は各[`agents/clients/NAME/module.nix`](../../agents/clients)の`supply.package`と`binary`が所有し、更新と世代の管理は`dotfiles-agent-supply`だけが行う。同じ profile の baseline 初期化、手動更新、timer、rollback、retention は一つの owner を通る。

profile は`~/.local/share/dotfiles/agent-profiles/<client>/profile`で、世代 link は Nix の GC root である。存在しない profile だけを locked baseline から作り、activation は latest を取得せず、既存 profile を巻き戻さない。更新は取得した供給元の exact revision から build と probe を行い、成功した client だけを公開する。一つの失敗は他 client の更新を止めず、外部取消は実行中の子の終了を待って次を始めない。current と直前の世代だけを残し、候補 root が build から公開までを保持する。採用外の client は更新、公開 command、通常の health から外れるが、profile と利用者 state は残る。

`dotfiles.agents.clientExecutables`は採用client IDからprofile内の実行pathへの対応で、profileの`bin`はPATHへ出さない。
公開commandはHome Managerが`~/.local/bin`より前へ置くwrapperだけである。
`runtime.managed`のwrapperはprofileの実行pathと、起動時に確定するmanaged config、hook、gate、runtime、Skill、rules、subagentの`clientExecutionDependencies`を受ける。
初回seedは保護対象に含めず、`runtime.unsupported`はprofileを直接起動する。
`dotfiles.agents.lifecycle`はwrapperのbuilder、GC rootを取る`protect`、子孫を回収する`supervise`をjournalとmemory harvestにも渡す。
`supervise`のownerは[`platform/supervise/`](../../platform/supervise)であり、rebuildの非特権処理も同じcommandを使う。
root activationの扱いは[Rebuild](../operations/rebuild.md)を参照する。
親の終了で取消を求めるcallerは`--parent-death-cancels`へ自身のPIDを渡すので、supervisorの起動準備より先に親が終了してもcommandを始めない。

adapter の対応なし、subagent、Skill 投影、LSP、telemetry、project memory は`dotfiles.agents.registry`の判別可能な枝で表し、policy の能力表はその枝から導く。`supply`、`rules`、各枝が参照する managed file の実在は構築時の整合として検査する。


lifecycleはsession ID、開始したproject、owner process、boot IDをsession directoryへ記録し、clientを`agents.slice`のscopeでsupervisorを通して一度だけ起動する。
[資源の上限](#資源の上限)はscopeのsliceが持つ。
管理scratchと、`TMPDIR`を条件にする終了gateの除外は、`TMPDIR`が未指定のときだけ与え、空文字列を含む明示値はそのまま渡す。
外側のsessionから管理scratchを引き継いだだけの`TMPDIR`は未指定として扱う。

supervisorはchild subreaperとして全子孫を引き取り、kernelが子の残りを報告しない`waitpid`の`ECHILD`で回収完了を観測する。
clientの終了、PTY終了の`SIGHUP`、`SIGTERM`で終了を始め、その時点の全子孫へ一度だけ`SIGTERM`を送る。
猶予中に生まれる後始末の子は中断せず、猶予後は新しい子も含めて`SIGKILL`で回収する。
既定ではSIGKILL後の猶予を過ぎても子孫が残ると非成功として返し、利用側はroots、scratch、sessionを解放しない。
`SIGINT`と`SIGQUIT`は既定ではclientの中の操作の取消であり、session全体の終了とは扱わない。
公開PIDだけが取消の窓口である利用側は`--interrupt-cancels`を明示でき、この指定では`SIGINT`も`SIGTERM`と同じsession全体の取消になる。
`SIGQUIT`に対するsupervisor自身の扱いは、この指定でも変わらない。
sessionの実行時間には上限を置かず、終了を始めてからの猶予だけを区切る。

子孫の終了確認を打ち切らずに待つ必要がある利用側は、supervisorへ`--require-drained`を明示する。
この指定ではSIGKILL後の猶予が過ぎても所有を手放さず、`ECHILD`を確認するまで返らない。
猶予の経過は完了とみなさず、stderrと`--result`の`draining`段階へ残るprocessの診断を出し続ける。
signalを拒むprocessとprocess tableを読めない状態も完了とは扱わず、同じ診断へ出して待つ。
`--hold-fd`はsupervisor自身が保持し続け、猶予後に切り離したholderは作らない。
指定しない既存のcallerは、SIGKILL後の猶予を過ぎても子孫が残る場合に、従来どおり`drained=false`と非ゼロの終了statusで返る。

取消後と開始途中の失敗ではclientを起動しない。
scopeを作れない場合もclientを起動せず、別sessionとMCP frontは止めない。
supervisorが先に消えた場合はscopeのcgroupが空になるまで残りを止め、終了を見届けてから解放する。
台帳のI/Oと`gc.lock`の待ちは起動と後始末で合計5秒までとし、超えた起動を拒否して使用中のsessionを回収しない。
起動前にwrapper、当該clientの`executionDependencies`、lifecycle自身、profileの公開pathから解決したstore objectへsessionのGC rootを取り、一つでも取れなければclientを起動しない。
その物理pathを実行するため、保護と起動の間にprofileが動いても別の版を実行しない。
全子孫の終了後にだけGC root、管理scratch、session directoryを解放し、解放できなかった資源はGCに残して非ゼロで終わる。

managed OMPを選択したhostは、評価の呼出し側が使うhost capabilityとして`~/.local/share/dotfiles-agent/evaluation-runtime.json`を読取専用で配備する。
内容は`version`、managed OMP wrapperの絶対pathと空の先行引数、`supervise`の実行path、完了契約`require-drained`だけである。
予算、model、保存先、資格情報、profileのnative binaryへの直接pathは持たない。
呼出し側はこのfileを`--config`で明示した設定の層として参照し、PATHやstoreのgenerationを前提にしない。

projectはGit repositoryではgit common directory、それ以外では作業directoryから決めるため、linked worktreeは元のcheckoutと同じprojectになる。
session中の`git worktree add`はgit shimがpathと作成時のHEADを記録し、終了時にはHEAD不変のworktreeだけを`git worktree remove`へ渡す。
変更、untracked file、lockを持つworktreeは同commandが拒否し、削除できなくてもclientの終了statusは変えない。
同時に走った別の`git worktree add`と区別できないもの、session外で作られたもの、SIGKILLで終わったsessionのworktreeは回収しない。
Orcaが作るworktreeの寿命はOrcaが持つ。

共通のcache方針は、process寿命を持つruntimeではなく[`toolchain/execution/`](../../toolchain/execution)が持つ。managed commandのwrapperは`dotfiles-execution-policy`を一度だけ適用してからlifecycleへ渡し、clientごとのcacheは増やさない。`CARGO_HOME`と`XDG_CACHE_HOME`が未設定なら共有cacheを使い、利用者が明示した値は空文字列も含めて変えない。Cargoの中間成果物は`CARGO_BUILD_BUILD_DIR`で全sessionが共有する一つのrootの下に置き、`{workspace-path-hash}`でcheckoutごとに分けるので、どのsessionからbuildしても同じcheckoutは同じbuild-dirを使う。最終成果物は各checkoutの`target`に残る。同じworkspaceのcheckoutどうしで中間成果物を共有すると、Cargoが別checkoutのbuildをfreshと判定するため、linked worktreeとも共有しない。利用者が明示した`CARGO_TARGET_DIR`と`CARGO_BUILD_BUILD_DIR`、project固有のCargo`target-dir`と`build-dir`は上書きしない。方針はdirectoryを作らず回収もしない。共有cacheとCargoのbuild root、sessionの台帳を作って検証するのはruntime、容量を回収するのはGCである。`nix build`と`nix-build`が結果linkを作らないshimも同じ方針が`PATH`の先頭へ置く。一時的な写しでbuildするtoolは、写しごとに中間成果物がbuild-dirのrootへ残るため、`CARGO_BUILD_BUILD_DIR`を外して起動する。

`dotfiles-agent-verify`はHEAD、tracked diff、non-ignored untracked content、command、環境からfingerprintを作り、同一fingerprintの成功だけを再利用する。
fileごとのprocess起動を避けるため、tracked fileのmetadataと内容hashはコマンド行長の上限内でまとめて取得する。
読み取り前後のmetadataを照合し、gitlinkはその内容まで再帰的に検証する。
宣言されたT1をrepositoryの根で呼ぶ場合は、入口解決、検査、成功証跡の保存と完了の記録を、走行開始から数えるprojectの予算で制限し、予算超過時は取消を開始して成功として扱わない。
別sessionへ移った子孫も`supervise --require-drained`で回収し、終了確認まで返らないため、後始末は予算を超えて続くことがある。
予算はrepositoryの根の`verification-budget.json`の`verify.seconds`を正本とし、wrapperは走行開始後に共通providerの`dotfiles-verify-entry --snapshot verify`で静的な宣言を一度だけ読む。
予算と入口は同じsnapshotを`--policy FILE`へ渡して解決するため、解決の間に登録を編集してもcanonicalな呼び出しが無期限のlocal cacheへ切り替わることはなく、snapshotの読取時間も走行開始から数える予算に含まれる。
走行中に宣言を書き換えても、その走行の期限は延びない。
Nixの入口は同じfileの`frontend: "nix"`と`entries`から解決し、入口の有無を調べるために評価器を起動しない。
Nixの取得と評価は検査本体の実行時にだけ行い、その時間も残りの予算で止める。
wrapperは固定の予算値を持たない。
T1の入口を認識したrepositoryで宣言が無い、または不正なら、既定値も無制限も補わず、入口を実行せず証跡も作らずに終了status 78で失敗する。
入口が無いrepository、入口の綴りに一致しないlocal command、根以外での実行は従来どおりcacheだけを使い、証跡を作らない。
宣言を読めないrepositoryでは評価器を起動せず、`--candidates`が評価を要しない置き場とflake.nixから集めた入口になり得る綴りだけで判別する。その綴りと一致する根での呼び出しは実行せずに拒否し、一致しないlocal commandは宣言が読める場合と同じくcacheだけを使う。
終了gateは登録済みの入口の予算を要求し、宣言の不正と追跡済みfileの欠落を入口なしとして通さない。
検証の証跡は走行tokenごとに、metadataの読み取り前後を照合した検査前のsourceへ固定し、時間内の保存と後始末を見届けたwrapperが完了を記す。
T1の走行中のmetadata変化はcache keyとは別に照合し、検査後に編集されたsourceへ証跡を結び直さない。
公開途中の証跡やまだ動いているwrapperの証跡は終了gateを開かず、期限超過や中断では同じ走行tokenの証跡と一時fileだけを回収するため、別の完了済み走行の証跡は巻き込まない。
wrapperの生存はPID、boot ID、processの開始時刻で照合するため、PIDの再利用や再起動で別のprocessが現れても完了済みの証跡を失効させない。
同じbootに居るproducerの開始時刻を読めない場合は、生存状態を確定できないため終了を認めない。
完了markerは末尾の改行まで揃った場合だけ受理し、file size制限による部分書込の失敗でも終了を認めない。
古い証跡の整理はT1へ含めず、終了gateが同じ木の完了済み証跡を受理するときに行う。

[`dotfiles-agent-gate`](../../agents/impl/runtime/gate.sh)は、Claude CodeとOMPの編集hookでfile pathに対応する配備済みSkillの読取記録を要求する。
OMP hook は write の本文と read の全文を JSON に含めたまま gate の stdin へ送り、read の証明を照合する Node process へも pipe で渡す。
argv に本文を載せないため、1 引数や argv 全体の容量制限で検証前に失敗しない。
20 秒の期限または中断では gate の process group 全体へ SIGKILL を送り、起動した子と出力 pipe の処理の終了を確認してから失敗結果を返す。
終了を確認できない間は診断を出して待ち続ける。
OMPのhookは、配備時に`@gateBinary@`を`dotfiles.agents.packages.verificationGate`のstore executableへ置換し、各callで`/run/current-system`を再解決しない。
具体的なstore executableを埋め込んだhookで開始したsessionは、generationを切り替えてもそのgateと成功して読んだ物理sourceのまま動き、新しいgateと実行packageは新しく始めたsessionへ届く。
この配備より前に読み込まれ、`/run/current-system`を参照するhookは、呼出しごとに現在のgenerationのgateへ解決されるため、旧gateの保持を主張しない。
編集対象はsymlinkと`..`を解決したpathで判定する。
agent runtimeが割り当てた`~/.cache/dotfiles-wsl/sessions/<session>/tmp`の内側にあり、祖先にGit metadataを持たない一時fileは対象から外す。
割当ての確認には、canonical pathの`<session>`と`DOTFILES_AGENT_SESSION_ID`の一致に加え、同じsession directoryの`metadata.json`が実fileであり、`version`が1、`session_id`が`<session>`と一致することを要求する。
metadataを持たない手作りのdirectory、別sessionの識別情報、不正なmetadataでは除外しない。
空であると確認できる実directoryの`.git`はmetadataに数えないが、空でないdirectory、file、symlinkは除外を認めない。
任意の`TMPDIR`、Git checkout内の一時file、checkoutへ向くsymlinkは対象から外さない。
記録するのは、成功した読取後のeventで観測した`skill://NAME`、`skill://NAME/SKILL.md`、設定済みSkill rootの`NAME/SKILL.md`の本文読取だけであり、呼出し前、失敗、reference、部分読取、編集操作は証拠にしない。
記録の前に、OMPの実resultが示すsourceと表示本文、Claudeの成功したtext resultが示すfile pathと本文を現在のcanonical本文へ照合し、省略、要約、token cap、途中のpage、本文を持たない結果は証拠にしない。
記録には配備先のsymlinkを解決した本文のSHA-256を保存し、編集時に現在の本文と照合するため、配備内容が変わったら読み直す。
`learned --session ID --path NAME`は、既存の配備済み本文を管理者が明示的に承認するための信頼された操作として残し、通常の読取hookの代わりには使わない。

`standard-conformance`のcanonical本文を成功した読取eventで読んだsessionは、応答の終了要求時に監査完了を確認する。
`standard-apply`だけの読取や管理者の`learned`操作から、この監査義務を推定しない。
`dotfiles-agent-gate standard-root`は、compiled configurationが持つ信頼された現行規範rootを出力する。
環境変数やproject内の写しで、このrootを置き換えない。
`dotfiles-agent-gate conformance --session ID --repo PROJECT --standard-root ROOT --report REPORT`は、規範rootと実行packageを別々に検証する。
ROOTは信頼された現行規範rootと物理pathが一致しなければならず、同じ物理rootを指すsymlinkは受理するが、同じ本文をコピーした別のrootは受理しない。
実行packageは、成功read時に記録した`SKILL.md`のsymlink実体のdirectoryである。
現在のSkill本文hashを照合してから、そのpackageの`scripts/check-coverage.mjs`をNodeで実行し、`--standard-root`へ現行規範rootを渡す。
規範本文だけが更新された場合は、保存済みのinventoryとreceiptが失効し、実行packageは変わらず識別されたまま使われる。
更新後の規範本文をそのpackageのcheckerが扱えない場合は、配送不足として失敗し、旧本文でPASSを作らない。
報告は対象Git checkoutの外に置き、baselineの正本は対象projectのrootを表す`PROJECT`の下の`PROJECT/docs/conformance-baseline.json`とする。
checkerがexit 0で`PASS`か`WARN`を返した場合だけ、観測した標準とprojectのdigest、報告とcheckerのhash、各pathをsessionのreceiptへ保存する。
終了時は現在のinventoryとこれらのhashを照合し、同じ木の`check`を重複実行せずに、確認の欠落や後の変更を拒否する。
旧配備のSkillにcheckerがなければ確認済みとして通さず、source updateと実session IDを含む実行commandを案内する。

OMPのgate起動例外は説明付きの非ゼロ結果となり、編集前と初回の応答終了時の判定はgateが起動しない場合も処理を止める。
停止hookの再指示中を示す`stop_hook_active`がtrueの終了要求で判定が再び失敗した場合は、警告とlogに結果を残し、追加の再指示を返さず利用者へ応答を返す。
この返却を検証や監査の合格にはせず、CLIの非ゼロ終了と成功receiptの作成条件は変えない。
利用者の新しい入力による終了要求では、再び初回の判定を行う。
読取後の記録、編集後のrepository登録、shell実行後の変更観測は実行済みのtoolを取り消せず、後段hook自体が失敗すると記録が残らないこともある。
終了時の検証gateが要求するのは、編集を記録したrepository自身が宣言するT1の`verify`入口だけであり、入口を持たないrepositoryには要求しない。
このgateは通常のhook経路でtoolが返した全文とその鮮度、成功readした実行packageと現行規範rootの対応、文書単位の監査完了を確認するもので、悪意あるagentからの防御、注意や理解、後続compactionでの本文保持、正しい監査対象の選択、証拠やcheckの意味と真偽、標準全体への意味的な適合を保証しない。
`dotfiles-doctor`の配備driftのPASSは配備物の同一性の観測であり、現行規範への適合を示さない。

## 資源の上限

wrapperから起動したclientは、launcherが`systemd-run --user --scope`で作るsession単位のscopeの中で、supervisorが一度だけ起動して動き、そのscopeはsystemd userの`agents.slice`に属する。scope名は`dotfiles-agent-<client>.<pid>.<suffix>.scope`で、session directoryの名前から導く。clientが起動したbuild、test、browser、VMもscopeに入るため、slice全体で次の上限を共有する。値は`dotfiles.agents.slice`のoptionで変えられる。

上限は物理RAMの割合で指定し、systemdが起動時のmemory容量から解決する。
`agents.slice`の`MemoryHigh`は60%、`MemoryMax`は70%、`MemorySwapMax`はRAMの20%を既定とし、CPUWeightは50にする。
swapの百分率はswap総量ではなく物理RAMに対する割合である。
値の正本は`dotfiles.agents.slice`であり、highよりmaxを大きくする。

Chromiumはuser busから`app.slice`へscopeを作るため、agent scopeから抜ける場合がある。
user manager全体にも`MemoryHigh` 67%、`MemoryMax` 75%を置き、agentとbrowserの合計を抑える。
user managerのmaxはagent sliceのmaxより大きくし、基盤とkernelへRAMを残す。
launcherはscopeを作れないとsupervisorもclientも起動せず、scope外のclientはdoctorの`agent/slice-placement`が報告する。
MCP sessionのbrowserは[`dotfiles-supervise`](../../platform/supervise)の下で起動し、sessionの終了でそのsessionのbrowserと子だけを終了確認まで止める。別のsessionとMCP front本体は止めない。

I/O上限やprojectの`CARGO_BUILD_JOBS`の上書きは加えず、memory上限でpage cacheとswapの圧迫を抑える。
agentが起動したNix builderはnix-daemonの子としてsystem.sliceで動くため、`agents.slice`の上限を受けない。
[`workstation/nix/module.nix`](../../workstation/nix/module.nix)がhostのjobs、cores、空き容量reserveを持ち、nix-daemonのCPUWeightを50にする。
Dockerが起こす宣言外のcontainerは[containerの配置と上限](#containerの配置と上限)で別に抑える。

## Policy、subagent、Skill

[`agents/policy/AGENTS.md`](../../agents/policy/AGENTS.md)は共通の作業規律を持つtemplateであり、Skill、subagent、Capabilityとclientの能力の一覧はNix宣言と各sourceのfrontmatterから生成する。
説明文書は同じ一覧を手で維持せず、正本の場所と現在値の取得方法を示す。
この環境ではAI CLIをclient、委譲先の定義をsubagentと呼び、`agents/subagents/`がその定義とroutingを所有する。
client形式への変換はbuild時に行う。

`native`と`rendered`のsubagentはhome配下へ配備する。Codexの`declared` subagentはhomeへsymlinkせず、`config.toml`の`[agents.<subagent>]`からNix storeの実体を`config_file`で指す。Codexがsubagent fileを`O_NOFOLLOW`で開き、symlinkを拒否するためである。
OMPのhookは`~/.omp/agent/hooks/pre`をdirectoryごとhomeへ配備し、その中をNix storeの実fileにする。OMPはhook directory内のsymlinkを読み込まず、Home Managerがfileごとに張るsymlinkでは全hookが無視されるためである。
client別の対応は各`agents/clients/<id>/module.nix`の判別可能な枝で宣言する。
`projectMemory`の`hooks`か`plugin`の枝は実在する`managedFile`を必須にし、`unsupported`の枝は配備先を持たない。
現在のtagは次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.clients --apply 'builtins.mapAttrs (_: client: builtins.mapAttrs (_: branch: builtins.head (builtins.attrNames branch)) { inherit (client) runtime rules subagents lsp telemetry projectMemory; })'
```

`projectMemory`はclient固有の想起注入の入口を表し、明示的な検索、検証、保存の判断を代替しない。

Claude CodeとCodexのuser configはclientが更新し得るため、Home Managerは配備先が存在しない場合だけseedを作る。seed は runtime drift の対象にしない。OMPの`config.yml`と`agent.db`もclient所有の可変fileとして残す。
OMPのseedはBash interceptorを有効にし、直接の再帰検索を専用検索手段へ誘導する。既存の`config.yml`はOMP自身の設定commandで移行する。

OMPのcompactionで利用者のmessageを要約と別に原文で残すのは、OpenAI ResponsesのV2 streaming compactionだけである。
それ以外の方法は直近の範囲より前を要約かarchiveだけで渡すため、要約が利用者の常設の指示を落とすと、agentは指示があったこと自体を知る手段を失う。
AGENTSにある、過去の利用者指示を会話の原文で確かめる規律も、存在を知らない指示には適用されない。
この欠落はupstreamのOMPで直す対象であり、seedの設定やpolicyの文では補わない。

## Web調査

Web検索とURL取得は、各clientが公開するnative toolを使う。この環境はWeb検索用のMCP providerもbackendも配備せず、公開するMCPはlibrary docsの`library-documentation`（Context7）だけである。
[`web-research`](../../skills/web-research/skill/SKILL.md)が問いの分解、source選択、根拠評価を所有し、検索の順位、snippet、生成された回答文をclaimの根拠にしない。

SearXNGとCrawl4AIは配備せず、検索と本文取得のための常設backendを持たない。
native readerがJavaScript描画後の内容を取得できない場合は、既存の`browser-operation`へ必要な項目の取得を渡す。
検索系のbackendを追加または代替する場合は、標準toolと既存ブラウザで得られる成果を明確に上回るかを実測し、RAM、CPU、secret、image、lifecycleの保守負担とあわせて判断する。

clientごとに公開されるtoolは次のとおりである。使えるかは配備したsessionのtool一覧で確かめる。

| client | 検索 | URL取得 | subagent |
|---|---|---|---|
| OMP | `web_search`。provider chainが応答し、`web_search.enabled`で有効にする | `read`へURLを渡す | frontmatterの`tools`が許可したtoolだけを持つ。`WebSearch`を`web_search`へ変換し、`WebFetch`は`read`で足りるため落とす。許可のないsubagentは検索を持たない |
| Claude Code | [`WebSearch`](https://code.claude.com/docs/en/tools-reference#websearch-tool-behavior)はtitleとURLだけを返し、Amazon Bedrockでは使えない | [`WebFetch`](https://code.claude.com/docs/en/tools-reference#webfetch-tool-behavior)は取得ページへのpromptの結果を返し、原文ではない。組織policyで止まり得る | [`tools`のallowlist](https://code.claude.com/docs/en/sub-agents)に`WebSearch`と`WebFetch`が必要 |
| Codex | `web_search`。[既定は`cached`](https://developers.openai.com/codex/config-reference)で、seedは`live`にしない | 専用toolは未確認 | rendererは`tools`を渡さない。継承は未確認 |
| OpenCode | [`websearch`](https://opencode.ai/docs/tools/)（ExaまたはParallel） | `webfetch` | `tools`へ`websearch`と`webfetch`を渡す。実機での稼働は未確認 |
| Antigravity | [CLIの公式仕様](https://antigravity.google/docs/cli/features)にはWeb検索の利用が記載されているが、この環境の実行は未確認 | [`read_url_content`](https://antigravity.google/docs/permissions)。権限`read_url`の既定はAsk | この環境はsubagentを配備しない |


`architect`と`planner`は`web-research`へ委譲するため、`WebSearch`と`WebFetch`を`tools`に持つ。
検索かURL取得を持たないsubagentでは、`web-research`が上位の呼出し元へ実行を依頼し、返された原応答だけを根拠にする。
この引渡しを含む自然発火と成果は測定しておらず、全clientで同じ保証を持つとは言えない。

## MCP Platform

各[`capabilities/`](../../capabilities)実装が`dotfiles.platform.mcp.targets`へprovider ID、executable、server transport、server lifecycle、port、通信要件、backend unit、probeを登録する。[`platform/mcp/module.nix`](../../platform/mcp/module.nix)はtargetからfrontを一度だけ導く。

GitHubとContext7の実行fileは、rootの[`nixpkgs-unstable` input](../../flake.nix)で固定したleaf packageから受け取る。
hostとHome Managerのpackage setはstableのまま変えず、providerごとのasset取得やnpm lockは持たない。
各providerの`serverBuilder`による実行時credential読込、toolset、port、probe、secret変更時のrestartと、clientにはgatewayだけを配る契約は変えない。
このpackage供給から同梱Skillの採用は導かず、Skillの採用と差替は既存のregistryが所有する。

`stdio`の`service` lifecycleは一つのstdio serverをfront serviceの寿命で共有する。`session` lifecycleはagentgatewayがdownstream sessionごとにstdio serverを生成する。`streamable-http`はproviderのforeground serverをfront serviceとして起動する。backendを持つtargetは`waitUnits`をfrontの`requires`と`after`へ設定する。

[`platform/mcp/gateway/module.nix`](../../platform/mcp/gateway/module.nix)は単一endpointのID、port、URL、service、runtime directory、YAML source、target名を公開する。gatewayは全frontへloopback HTTPで接続するが、front serviceを起動依存に持たず、子processも作らない。各AI CLIが知る接続先はこのURLだけである。

browser automationとbrowser diagnosticsは異なる観測contractを持つが、[`capabilities/browser-runtime/chromium/module.nix`](../../capabilities/browser-runtime/chromium/module.nix)のChromium packageを共有する。tab、page、browser processはdownstream session間で共有しない。
`browser-diagnostics`のSkill入口はcustom `browser-performance`、LCP専門の`debug-optimize-lcp`、実画面監査の`a11y-debugging`であり、Playwright操作の入口は`browser-operation`である。
一般の`diagnosing-bugs`はbrowser Capabilityを要求せず、必要なbranchだけ専門入口へ渡す。
heap-diagnosticsのregistryは[`capabilities/heap-diagnostics/module.nix`](../../capabilities/heap-diagnostics/module.nix)が所有し、providerは`memlab`だけ、backendとCapability依存は空である。
入口の`heap-analysis`はheap-diagnosticsだけを要求し、heap artifactをproject-memoryへ送らず、ChromeまたはNode.jsのlocal snapshotと比較条件を扱う。
native .NET/Rustのdump、RSSだけの増加、歴史的memoryの検索や保存は所有しない。

providerの[`module.nix`](../../capabilities/heap-diagnostics/memlab/mcp/module.nix)はport `8777`、stdioのsession lifecycle、`needsNetwork = false`を宣言し、downstream sessionごとにresident snapshotとhandleを分離する。
共通frontの`MemoryMax = \"2G\"`とは別に、[`package.nix`](../../capabilities/heap-diagnostics/memlab/mcp/package.nix)がNode old-spaceを`1024` MiB、解析timeoutを`45000` msへ制限する。
fileを載せる前にheaderと現在のresident stateを調べ、重いwalkや複数loadを並行させず、不要なsnapshotをunloadする。

配備するのは固定archive hashとpackage-lockを持つpublished `@memlab/mcp-server` `2.86.0`であり、調査用Git sourceの`915` prefixの版と同一視しない。
published packageが持つsnapshot headerとmulti-snapshot APIを基準に、現在のschemaを確認する。
原版のtool bodyは変更せず、localの[`readonly-server.mjs`](../../capabilities/heap-diagnostics/memlab/mcp/package/readonly-server.mjs)を追加し、33の解析・session登録だけを公開する。
`eval`、`for_each`、`eval_across`、`batch`と任意codeを実行するcomposite経路は登録しない。
この入口制限をVMによる安全なsandboxやheap内の秘密情報の無害化と呼ばず、取得許可、絶対path、localでの保持、報告時の秘匿化を別に守る。

[`admission.mjs`](../../capabilities/heap-diagnostics/memlab/mcp/package/admission.mjs)はlocalの絶対pathだけをloadに許可し、`force`によるadmissionの回避を拒否する。
比較はguard付きでload済みのresident snapshotだけを受け付け、fresh fileから比較APIへ直接入る経路を拒否する。
[`supervised-server.mjs`](../../capabilities/heap-diagnostics/memlab/mcp/package/supervised-server.mjs)はsession専用workerのstdioをpipeにし、同期処理にも独立したdeadlineを適用する。
deadlineを超えたworkerだけを終了し、未完了の解析を空の結果として返さず、他sessionのgraphには触れない。
これはNode old-spaceの上限であり、processのRSSを1 GiB以下に保証するものではない。

Chrome MCPのruntimeと同梱Skillの供給元は、[`flake.nix`](../../flake.nix)の`chromeDevtoolsMcp` inputに統一する。
起動時には`--no-usage-statistics --no-performance-crux`を指定し、usage統計の送信とtrace URLを用いるCrUX照会を無効にする。

Chromeのfile exportの保存先制限は、clientのtool harnessやgatewayではなく、固定したChrome MCP packageのcanonical path検査が所有する。
[`package.nix`](../../capabilities/browser-diagnostics/chrome-devtools/mcp/package.nix)は既存frontの`runtimeDirectoryPath`を`mk-server`の`env.TMPDIR`とCLIの`--filesystemRoot`へ渡し、systemdがmode `0700`で所有するprivateな領域だけを既定の保存先にする。
providerはcallerごとに割り当てた`TMPDIR`を起動時には知らないため、callerのsession cacheやworkspace全体をfilesystem rootへ追加しない。
[`browser-performance`](../../skills/browser-performance/skill/SKILL.md)はtrace、screenshot、heapに共通のprovider-owned private stagingを作り、capture後のfileをmode `0600`でcallerの`TMPDIR`へ移動して自分のstagingを回収する。
[`heap-analysis`](../../skills/heap-analysis/skill/SKILL.md)は転送後のlocal fileを公開MemLab toolへ渡し、不要なresident graphと自分のfileを回収する。
privateなruntime保存先が拒否された場合はcapture不能を報告し、repository、symlink、共有`/tmp`への保存や無制限path設定で回避しない。
外部のtool例があっても、実tool schema、gateway接続、account選択、権限、副作用の安全境界を取込側の契約で確認する。

現在のtarget名は次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.targets --apply builtins.attrNames
```

## Container Platform

[`platform/containers/module.nix`](../../platform/containers/module.nix)は型付きservice contract、Docker daemon、`dotfiles-backends` network、OCI image inventory、image同期を所有する。[`platform/containers/impl/container-backend.nix`](../../platform/containers/impl/container-backend.nix)はCapability実装が使うpure builderである。

application固有のcontainer、endpoint、credential、volume、provisioningは対応するCapabilityが所有する。Hindsightをgeneric Platformへ列挙しない。

Capability実装はregistry metadataを常に宣言し、backend、MCP target、credential、永続data、health observation、client integrationを`dotfiles.capabilities.resolved`で条件化する。
container backendもruntime imageも選択しない場合、Container PlatformはDocker daemon、共通network、image同期command、GC timerを配備しない。

全containerは暗黙pullを無効にする。upstream imageはdigest固定の宣言と、containerを有効にしたhostへ配備する`dotfiles-sync-images`が取得を担当し、Nix生成imageは`imageFile`が取得を担当する。
Docker build artifact GCは停止済みのtestcontainersのcontainer、dangling image、BuildKit cacheを扱い、tagged image、named volume、それ以外のcontainerは削除しない。

### containerの配置と上限

Docker daemonの`cgroup-parent`は`containers.slice`であり、`--cgroup-parent`を持たないcontainerはすべてこのsliceの`docker-<id>.scope`に入る。
agentのtestがtestcontainersで起こすcontainer、compose、手で起こしたcontainerがこれに当たる。
宣言済みbackendは[`container-backend.nix`](../../platform/containers/impl/container-backend.nix)が`--cgroup-parent=system.slice`を付けるので、基盤のserviceと同じsystem.sliceに残り、このsliceの上限を受けない。
[dockerd reference](https://docs.docker.com/reference/cli/dockerd/#default-cgroup-parent)によれば、containerごとの`--cgroup-parent`はdaemonの値より優先され、systemd driverではslice名がcgroup treeの位置を表すので、`containers.slice`はroot直下に作られる。
[systemd.slice(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.slice.html)によれば、sliceに置いた資源の上限はslice内の全unitのprocessに効く。
[Control Group v2](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files)によれば、`memory.current`と`memory.swap.current`は子孫のcgroupを含めて数えられ、`memory.max`に達して回収できなければそのcgroupの中でOOM killerが動く。

宣言外のcontainerの上限は物理RAMの割合であり、`MemoryHigh` 7.5%、`MemoryMax` 10%、`MemorySwapMax` 10%、CPUWeight 50を使う。
user managerとcontainerの上限を分け、system.sliceの基盤とkernelにRAMを残す。
system managerのdockerdはuser managerへ委譲したsubtreeにscopeを作れないため、containerを`agents.slice`へ入れない。
testcontainersなどの呼出し元が個別の`--memory`を指定しない場合も、daemonのsliceで合計を抑える。

doctorの`container-placement`は、runningのcontainerごとにscopeのsliceをsystemdに問い合わせ、宣言済みbackendがsystem.slice、それ以外が`containers.slice`にいなければfailにする。

### 停止済みのtestcontainersの回収

Rust版のtestcontainersはRyukを持たず、containerの破棄をtestのprocessに任せる。
processがSIGKILLされるか、docker APIの要求がclientの期限を超えると、containerは所有者のないまま残る。
`docker-build-artifact-gc`は6時間ごとに、label `org.testcontainers.managed-by=testcontainers`を持ち、状態が`created`、`exited`、`dead`のいずれかで、作成から6時間を過ぎたcontainerを匿名volumeとともに削除する。
6時間はtimerの周期と同じ値で、作成からstartまでの途中にあるcontainerを消さないための下限である。
session単位で判定しないのは、`org.testcontainers.session-id`のlabelが`reusable-containers` featureを有効にしたときにしか付かないためである。
`running`のcontainerは所有者の生死を判定できないので削除せず、`containers.slice`の上限の内に置いたまま、作ったprojectの破棄処理で直す。
`docker rm`は`--force`なしではrunningのcontainerを拒むので、一覧を取った後にstartされたcontainerも削除されない。
回収は`docker image prune`より前に走り、削除したcontainerだけが参照していたtagのないimageを同じ実行で回収する。

## Project memory

現行のproject memory実装は[`capabilities/project-memory/hindsight/`](../../capabilities/project-memory/hindsight/)が所有する。`backend`はHindsight、`runtime`は`bin/dotfiles-memory`を含むpackage、`mcp`はmemory providerのfront、`client-integrations`は共通hook packageとOpenCode pluginをそれぞれ持つ。Capabilityが公開するgeneric optionは`dotfiles.capabilities.project-memory.runtime`と`dotfiles.capabilities.project-memory.clientIntegrations.{hooks,opencodePlugin}`であり、client moduleはprovider名やbackend pathを直接参照しない。

```text
Claude Code / Codex / OMP hooks ─┐
OpenCode recall plugin ──────────┤
agent memory harvest ────────────┼─► dotfiles-memory ─► 127.0.0.1:3111 Hindsight
                                 │                         │
AI CLI ─► gateway ─► memory MCP ┘                         └─► hindsight-data volume
```

memory MCPのendpointは`front`のport `8774`、Hindsight APIは`localhost:3111`である。MCPの入口は`memory_health`、`memory_recall`、`memory_save`、`memory_status`、`memory_verify`で、project/globalのscopeを明示する。healthはHindsightのdatabaseとmodel readinessだけを確認し、LLMが利用できることやretainが成功したことは証明しない。

project scopeのidentityは、`dotfiles-memory`が絶対cwdからGit common directoryを解決して導く。
同じrepositoryのlinked worktreeは共有し、basenameが同じ別repositoryは分離する。

Hindsightの原文書類はnamed volume `hindsight-data:/home/hindsight/.pg0`に保持する。宣言で固定したmultilingual embeddingとrerankerのmodel mountはNix storeからread-onlyで渡し、retain時のextraction inputはSOPSから展開したcredentialで設定する外部LLMへ送られる。

抽出modelは定額のOpenCode Goで呼べる`minimax-m3`であり、保存すべき内容の判断を抽出modelへ委ねない。
client連携はsession開始とprompt送信で想起結果を注入し、会話turnをHindsightへ保存しない。
promptから既知の注入blockを除いた残りが空なら想起せず、残った利用者発言にだけprivacyと長さの検査を行う。
通信失敗は接続、読取り、書込み、pool、protocolの固定した分類で報告し、query、接続先、応答本文、例外の表示は報告へ含めない。
分類を詳しくしてもerror codeは`unavailable`のままであり、送信済みのsaveを確認できない場合の`indeterminate`は変えない。
保存は明示的な`memory_save`と、有効にした[記憶の収穫](#記憶の収穫)が行う。

OpenCodeのrecall結果は同じturnのmodel呼出しで共有し、次のpromptで置き換え、idleで破棄する。title生成などの補助呼出しで消費しない。hook実行には30秒、警告通知には1秒のabort期限を設定する。event loopやhostが停止している時間を含めた実時間の上限は保証しない。

既知のmemory/injection blockは決定的に除外するが、secretやPIIをすべて検出できる保証ではない。失敗時に別のmemory backendへfallbackしない。saveが`pending`または`indeterminate`なら保存済みと扱わず、返されたoperationとdocumentのIDを同じscopeの`memory_status`へ渡して確認する。`indeterminate`は送信後の通信断や期限切れで結果を確認できない状態で、runtimeはsaveを自動再送しない。

LLM処理は外部endpointを使う。API keyはSOPS templateからroot所有のruntime environment fileを経てcontainerへ渡し、client hookやMCP frontへは配らない。明示的な保存と記憶の収穫のretain入力が外部providerへ送られる信頼境界を持つ。

## 作業日誌

`dotfiles.agents.journal.enable`で明示的に採用したOMP hostだけに配備する。

[`agents/journal/`](../../agents/journal)は、omp の session 記録から日次の作業日誌を作る。project memory が判断を想起のために蓄えるのに対し、作業日誌は全 project の作業を日付順に読める記録として残す。入力は`~/.omp/agent/sessions/`直下の project ごとの session file で、親 session の隣に置かれる subagent の記録は親と内容が重なるため読まない。各 entry の時刻で 06:00 から翌日の 06:00 までを切り出し、利用者の指示、エージェントの応答、tool の名前と意図だけを model へ渡す。thinking、tool の結果、tool の引数は渡さない。project ごとの commit 一覧は Git から読む。

要約は omp の print mode で二段に行い、session ごとの要約を project ごとにまとめる。起動時は session file、rules、Skill、自動検出する extension、tool を読み込まない。project memory の hook は extension とは別に読み込まれることがあり、prompt ごとに cwd の Git common directory から決まる project の記憶を想起して注入する。このため要約は Git の work tree ではない一時 directory で実行し、一時 directory が work tree の中にあれば model を呼ばずにその日を失敗にする。この cwd では project が決まらず、記憶は model の入力に混ざらない。model は omp の`tiny`役割と同じ`opencode-go/deepseek-v4.1-flash`で、認証は omp が保持するものを使う。session の本文には secret や個人情報が混ざり得る。prompt は秘密に見えるものを書かないよう指示するが、検出を保証しない。日誌の repository への commit は全 repository 共通の Git hook を通るが、pre-commit hook が拒否するのは GitHub token の形だけである。

日誌の repository は`dotfiles.workstation.environmentDir`の下に置き、flake の入力にはしない。dotfiles が配備した timer が書き込む出力だからである。

## 非対話 job の寿命

日誌と収穫は、user manager の`agents.slice`に置く oneshot service と timer で定時に動く。手動の`dotfiles-agent-journal`と`dotfiles-agent-memory-harvest`も、同じ job entry を同じ worker へ向けて呼ぶ。timer の service は自身が寿命を持って job entry を直接呼び、manual command は共通 runtime が scope と一時領域を与えてから job entry を呼ぶので、対話用の wrapper は二重に挟まない。

job entry の runner（[`agents/job/`](../../agents/job)）は、同じ job の writer を一つに絞る。排他は user の runtime directory の lock で、timer の実行中に手動で同じ job を呼ぶと worker を始めず非ゼロ（75）で返す。別の job は止めない。lock の fd は共通の supervisor（[`platform/supervise/`](../../platform/supervise)）が保持し、worker と子孫へは渡さない。runner が先に消えても、supervisor が全子孫の終了を kernel の観測で確かめるまで排他は保たれ、runner の死は job の取消として supervisor が子孫を回収する。

実行の上限は 6 時間で、manual と timer のどちらにも同じ値を適用する。
runner は開始時刻から数えた絶対時刻を`DOTFILES_JOB_DEADLINE`で worker とその子へ渡し、到達すると supervisor へ取消を送る。
この期限は実行依存の保護から worker の終了までを通して一つである。
worker は model、Git、memory command の待ち時間をその期限で絞り、期限後は新しい子を始めない。
子孫の終了を求める TERM、猶予（60 秒）、KILL、終了の確認は supervisor だけが持ち、猶予の経過は完了の判定にならない。
supervisor が全子孫の終了を確認できなかった場合、runner は実行依存の保護を残して 70 を返す。
期限と取消は成功として返さず、期限は 124、取消は 128 に signal 番号を足した値で終える。
supervisor は SIGINT を無視するので、runner が INT を取消として TERM に変えて渡す。

起動前には worker が後から呼び得る実行依存（client の profile、managed config、hook、gate、memory runtime）を、共通 runtime の`dotfiles-agent-protect`で GC root に置く。
保護の command も worker と同じ supervisor の下で、同じ期限と取消を受けて動かす。
期限か取消で保護が途中で止まっても、`nix-store`などその子孫の終了を supervisor が確認するまで、root と lock は解かない。
置けない依存があれば worker を始めない。
root は supervisor が全子孫の終了を確認した後にだけ解く。

client の profile の実行 path は保護の後も別の版へ動くので、job は model を呼ぶ実行 path を`--executable <option名>=<path>`として runner へ宣言する。
runner は worker の引数に利用者が`--omp`で明示した値があればそれを含めて、実効の一つだけを保護の command へ渡し、解決した物理 path を`--omp`一つとして worker へ渡す。
`--omp=<path>`の形も同じに扱い、略記した`--om`は保護できないので拒否する。
worker は受け取った物理 path だけで model を呼ぶので、profile が別の版へ移っても元の版へ戻っても、保護した版と実行する版は分かれない。

日誌の公開は、生成した file、local commit、remote の内容を分けて判定する。file があるだけの日と、commit だけで push されていない日は公開済みと扱わず、次の通常の実行が本文を作り直さずに未完了の段から続ける。公開済みと言えるのは、`origin`の branch が同じ内容の file を持つ日だけである。

## 記憶の収穫

`dotfiles.agents.memoryHarvest.enable`を明示的に採用し、OMPとproject-memoryが有効なhostだけに配備する。

[`agents/memory-harvest/`](../../agents/memory-harvest)は、omp の session 記録から利用者の訂正、決定、好みを取り出し、project memory へ保存する。session 記録の読み方と omp の呼び出しは作業日誌の package を読み込んで共有し、model も作業日誌と同じ定額の`opencode-go/deepseek-v4.1-flash`と thinking `low`を使う。作業の大半は omp で行うため、Claude Code、Codex、OpenCode の session 記録は読まない。

入力は`~/.omp/agent/sessions/`直下の session file のうち、前回成功した実行から今回の開始までの entry である。attribution が`user`の発言だけを読み、`<project_memory>`と`<system-reminder>`の block を除く。エージェントの応答、tool の結果、注入した文脈、subagent の記録は model へ渡さない。cwd から Git project を決められない session は読まずに報告する。
modelを呼ぶ前に`dotfiles-memory validate`へ発言の全文、保存済みの記憶のkindと本文、projectのpathを渡し、保存時と同じ既知の資格情報や個人情報の指標で検査する。
日本語の文に直接続く既知形式のAPI keyも不許可とし、URLの資格情報検査は本文を切り詰めずに行う。
このcommandはbackendへ接続せず、検査対象の本文を返さない。
発言と保存済みの記憶は不許可のrecord全体を除き、projectのpathが不許可なら見出しへ含めない。
長い本文をclipするのは検査を通した後であり、不正な応答や検査失敗ではmodelを呼ばず、読み終えた位置も進めない。
指標に合わないsecretや個人情報まで検出できる保証はなく、作業日誌の送信前検査には使っていない。

model には project ごとに、明示的に保存した記憶（`dotfiles-memory curated`）と利用者の発言を渡し、将来の別 session の判断を変える発言だけを候補にさせる。次の発言は候補にしない。今回の作業への依頼、計画、進捗の確認、質問、同意だけの返事、その場だけの許可や禁止、状況に依存する優先度や締切、人の名前を含むもの、利用者が標準、AGENTS、Skill、文書、hook、code へ入れるよう求めた規律、製品の仕様、現在の状態から分かること、保存済みの記憶と同じ内容、secret や個人情報を含むものである。正本に入るものを記憶に重ねないためである。

modelは候補ごとに、将来の別sessionで同じ判断を迫られる場面を一行で書き、書けない発言は候補にしない。
場面を保存する本文には含めず、保存済みのsourceと同じ発言はmodelへ渡さない。
保存済みの記憶と文字列が一致する候補も保存しない。

候補は一件ずつ`dotfiles-memory save`へ、scope `project`、session の cwd、kind、source `<session file>#<entry id>`で渡す。`pending`または`indeterminate`の receipt は保存済みと報告せず、受け取った時点で state file へ書き、次の実行で`dotfiles-memory status`へ渡す。取消や runner の突然死でも、受け取った receipt は失われず、送り直しもしない。保存済みと報告できるのは、`save`か`status`が backend の保存確定を返した場合だけであり、service の exit status は抽出と確認の成否を表し、保存の確定ではない。実行の最後に`summary:`の行で、抽出の成否、backend が確定した件数、確定していない receipt の件数を別々に出す。state file の読み終えた位置は、全 project の取り出しが成功した実行だけが進める。位置は読んだ範囲であり、確認待ちの receipt が残っていても進む。全件の保存が完了したと言えるのは、確認待ちの receipt が 0 件になったときだけである。runtime が資格情報や個人情報に見える候補を拒んだ場合は、その候補だけを捨てて失敗にしない。発言は model の provider へ、保存した内容は Hindsight の抽出 model へ送られる。運用は[記憶の収穫](../operations/memory-harvest.md)に従う。

## LSPと観測

language serverの登録とPATHへの配備は`toolchain/`が所有し、hostは`dotfiles.toolchain.enabledLsp`で登録済みIDを重複なく選ぶ。空集合と部分集合を選べ、未知IDと重複は評価で拒否する。
client形式への写像は各[`agents/clients/`](../../agents/clients)のadapterが持つ。Claude Codeはplugin、OMPは`lsp.json`、OpenCodeはconfigの`lsp` blockへ、採用したserverだけを投影し、非採用または未対応clientには配らない。

managed file は artifact owner が observation を登録し、doctor が current source との不一致を検査する。

telemetry collectorは対応するclientの採用時に有効となり、`dotfiles.telemetry.enable`で無効にできる。
OMP-onlyなどtelemetry未対応の採用集合では、collector、配備物、health観測を配備しない。
有効なcollectorはOTLPをloopbackで受け、生recordを残す。
CLIはendpointを`dotfiles.telemetry`から読み、portを重複して宣言しない。
