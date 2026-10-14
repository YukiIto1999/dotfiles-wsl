# Rebuild

**読み手:** 設定を適用する運用者と、適用の失敗や中断から復旧する運用者が、作業中に読む。

通常の適用と前世代へのrollbackは`dotfiles-rebuild`を入口にする。
適用は、確認した候補のstore pathをnativeの`nixos-rebuild`へそのまま渡す。
NixOSのgenerationは復旧対象を保持するが、switchの非ゼロ終了だけでは、profile、`/run/current-system`、各serviceの状態が一致しているか判断できない。
このcommandは、失敗の後にcheckoutとsystemのどちらが変わったかを観測して報告し、復旧済みとは表示しない。

## 適用

checkoutの変更を確認してcommitし、planを確認してから、そのplanの候補を適用する。

```sh
dotfiles-rebuild --plan
dotfiles-rebuild --candidate ID
```

`--plan`はcommit済みのsourceを隔離した複製へ取り出し、その中で次を順に行う。

1. 標準の実行packageである`architectureStandard`を最新へ更新し、`flake.lock`に固定する。
2. 隔離したsourceで、`verification-budget.json`が宣言する`verify`の入口を宣言の予算内で通す。
3. 対象hostのtoplevelをbuildし、native GC rootを`--out-link`で取得して候補として保持する。
4. 候補とWSLの現在状態から再起動の分類を求め、差分とともに表示する。

planは元のcheckout、HEAD、index、`flake.lock`、配備済みのgenerationを変更しない。
成功したplanは候補のIDを表示する。
候補は、`--candidate ID`で適用するか、`--discard ID`で破棄するか、次のplanが置き換えるまでGCから守られる。
公開決定前のplanの失敗と取消は、保持中の候補を変えない。
planの公開と、置き換える旧候補の解放は、一つの排他区間で行う。
並行したplanはこの区間で直列になり、互いの候補を消し合って一つも残らない状態にはならない。
公開前に失敗または取消されたplanの候補は、公開されないまま解放される。
公開lockの待機も取消の対象とし、lock取得後に取消要求を確認してから公開を決める。
公開を決めた後は、候補の保持と旧候補の解放を途中で分断しないため、短い公開区間を完了して成功として返す。
適用、rollback、`--discard`が書き手の排他を持つ間は、使用中の候補を守るため旧候補を解放せず、そのplanの候補を加えて保持する。
次のplanが、残った旧候補を解放する。
公開区間は短いが、その間は書き手の排他を取るため、同じ時に始めた適用、rollback、`--discard`は終了status 2で拒否される。

引数なしの`dotfiles-rebuild`は、同じ手順で候補を用意して、そのまま適用する。
この場合の候補はreceiptを公開せず、適用の成否にかかわらず終了時に解放される。
表示されるIDは後から使えないため、確認したplanをそのまま適用したいときは`--candidate ID`を使い、引数なしの実行を代用しない。

### 適用の手順

適用はrollbackと同じ書き手を共有し、同時には一つだけ走る。
走行中に別の適用、rollback、`--discard`を始めると、待たずに終了status 2で拒否する。
書き手の排他は、このcommandが終了するまで保たれる。

書き手を取った後、次の順に進み、段ごとに元のsourceとprofileを読み直す。

1. tracked、staged、non-ignoredの未追跡、`assume-unchanged`と`skip-worktree`の印を確認し、差分があれば終了status 2で止まる。
2. `--candidate ID`では候補の記録を読み、GC rootとstore path、保存したlock、plan時のHEADとlockが今のcheckoutと一致することを確かめる。
   失効または不一致なら別の候補をbuildせず、適用前に終了status 2で拒否し、その候補を解放する。
3. 現在のsystem状態から再起動の分類を求め直す。
4. 候補が新しいstandardのrevisionを含むときだけ、候補のlockを`flake.lock`へ書き、`fix: 標準の実行 package の最新版への更新`として一つのcommitにする。
   Gitのref transactionで元のHEADと参照先を固定し、基点のcommitとcleanなworktreeを要求してからlockを書く。
   書き込みはGitのtree更新（`git read-tree -m -u`）が行い、indexとworktreeの`flake.lock`が基点のbyteを保っている間だけ両方を更新する。
   別の編集とstagedは上書きせず、基点が動いていれば何も書かずに終了status 4で止まる。
   一時的なnative linked worktreeのprivate HEADで、元のworktreeとindexを使って`git commit`と設定済みのhookを実行する。
   hookが参照するHEADはprivate HEADであり、元のbranch名を返すとは限らない。
   元worktree固有の設定は、元の`config.worktree`をnative includeで参照し、相対includeの基準を変えずに引き継ぐ。
   branchやGit directoryに依存する条件によって実効設定が変わる場合は、hookを別の設定で走らせず、lockを書く前に拒否する。
   `--no-verify`、`core.hooksPath`の変更、`dotfiles.hooks.trusted`の付与は行わない。
5. 公開前のcommitがlockだけを変え、そのlockが候補と一致し、基点直下に載り、worktreeがcleanであることを確かめる。
   排他を解いた後、基点のcommit IDをold-oidに指定したnative `git update-ref`で元のHEADへ公開し、間に入った別のHEAD更新を上書きしない。
   排他とold-oidの照合は、[`git update-ref`のtransactionとcompare-and-swap](https://git-scm.com/docs/git-update-ref)を使う。
6. commit hook終了後のcheckoutを、既存のsource-bound検証である`dotfiles-agent-verify`で`verify`の入口へ通す。
   隔離したsourceの成功証跡はこの段へ移さない。
   成功証跡はcheckoutのpathとHEADごとに取り直し、再利用はNixの不変な成果物とcacheだけが担う。
7. 同じcheckoutのtoplevelを評価し、その結果が保持した候補のstore pathと一致する場合だけ進む。
   file内容の一致では代用せず、Git metadataの影響も評価結果に含めて照合する。
8. 評価と検証の間にHEADや作業木が動いていないことを確かめ、`nixos-rebuild switch --no-reexec --store-path`へ候補のstore pathを渡す。
   flakeを再び解決せず、nativeの`nixos-rebuild`は候補をbuildも評価もしない。

nativeの`nixos-rebuild`は端末のforegroundで走る。
このcommandだけに届いた取消は、activationの途中で子を止めず、終了を待ってから結果を報告する。

候補の用意、検証、buildの子は、共通の[`dotfiles-supervise`](../../platform/supervise)の下で、親の死でも取消される設定で走る。
取消は全子孫へTERM、猶予、KILLの順に届き、supervisorが全子孫の終了を確認してから作業用directoryと候補のrootを解放する。
このcommand自身がSIGKILLされても、実行中のbuildは孤児として残らず、supervisorが同じ取消で全子孫を止める。
確認できない場合は、動いている可能性のあるprocessが使うため、作業用directoryと候補のrootに`unconfirmed`の印を付けて残し、解放のIDを表示する。
印のある物は、後続のplanの置換、pruneのいずれも解放せず、`--candidate ID`でも適用しない。
activationはこのsupervisorの下に置かない。
取消のTERMとKILLがrootのactivationを途中で止め、profileとserviceを部分適用のまま残すためである。

### 標準の更新

通常の適用と`--plan`は`architectureStandard`だけを更新し、他のinputは変えない。
更新を取得できない場合は警告で済ませず、終了status 2で止まり、checkoutとsystemを変えない。
取得できた最新が既にlockの版なら、`flake.lock`は変わらずcommitも作らない。
更新が`architectureStandard`の外のlockを変えた場合も、適用せずに止まる。

オフラインなどで最新を取得できない場合の修復は、別の明示した操作として分ける。

```sh
dotfiles-rebuild --locked --plan
dotfiles-rebuild --locked
```

`--locked`は取得もlockの更新もcommitもせず、`flake.lock`のrevisionでそのまま候補を作る。
実行packageはlockの版のままであり、最新の標準を適用した証拠にならない。
規範本文は現行規範のrootから読むため、この操作が古い本文の適用を許可するわけではない。
実行packageが現行の本文を扱えなければ配送不足として失敗し、配備版の古い本文や別の写しへfallbackしない。

### 終了statusと結果

| status | 結果 | checkoutとsystem |
|---|---|---|
| 0 | planの成功、または適用の完了。`switch`と`switch-restart`を含む | 適用の完了ではsystemは候補になっている |
| 2 | 拒否または失敗。dirty、取得失敗、検証失敗、build失敗、失効した候補、書き手の競合、引数の誤りを含む | HEAD、index、作業木、systemは実行前のまま |
| 3 | 適用したが、WSLのboot移行が終わっていない | systemのprofileは切り替わっている |
| 4 | checkoutが変わり、systemは切り替えていない | lockのcommitが残る、または作業木に差分が残る。適用の途中に入った別の編集は上書きされない |
| 5 | activationが始まった後に失敗または中断した | profile、running system、serviceが部分適用のことがある |
| 130 | 何も変える前に中断された | 実行前のまま |

終了status 4は、結果の行に`source-changed`と表示し、基点のcommit、今のHEAD、残った差分を示す。
lockのcommitが残った場合は、commit済みだが未適用であることを明示する。
commit hookが`flake.lock`以外を変えた場合、検証の間に作業木が編集された場合、検証や評価の照合に失敗した場合がこれに当たる。
hookが候補commitやworktreeを変えた場合、そのcommitは元のHEADへ公開せず、hookの編集を残して止まる。
適用の途中で別の書き手がHEAD、index、作業木を変えた場合も、`flake.lock`を書く前に止まり、このcommandはcommitを作らず、その変更を残す。
このcommandは、残った変更を一律には戻さない。
戻すのは、commitを拒否されたときに、このcommandが書いた`flake.lock`のbyteがfileとindexにそのまま残っている場合のその一fileだけである。
この確認と復元はGitの同じtree更新が一度に行うため、確認の後に入った編集を上書きしない。
終了が確認できた一時worktreeはnative `git worktree remove`で登録ごと解放し、終了未確認の走行の登録は作業directoryと共に保持する。
登録を解放するのはこのcommandの終了処理であり、lock更新のhelperが先に終了しても、hookが残した子孫の終了確認までは保持する。

終了status 5は、結果の行に`activation-failed`と表示し、観測したprofile、running system、clientの配備先を示す。
復旧済みとは表示しない。
lockのcommitがあれば、残っていることも示す。

commit済みで未適用の状態からは、原因を直して引数なしの`dotfiles-rebuild`を再び実行する。
lockは既にHEADにあるため、新しいcommitを作らず、同じ手順で候補を用意して適用する。

## WSLの再起動

再起動の分類は`switch`、`switch-restart`、`boot-restart`、`boot-two-stage`のいずれかである。

| 分類 | 適用後の結果 |
|---|---|
| `switch` | 再起動を要しない。終了status 0 |
| `switch-restart` | runningは新しいgenerationで、WSLのmanifestの反映に再起動を要する。終了status 0 |
| `boot-restart`、`boot-two-stage` | boot移行が終わっていない。通常のswitchの成功として畳まず、終了status 3 |

どの分類でも、このcommandはWindowsの`wsl.exe --terminate`を実行しない。
他のsessionの作業が終わってから、表示された対象hostの`dotfiles.workstation.wsl.distroName`を使うcommandをPowerShellで実行する。
これはLinuxのユーザー名やhost IDではなく、Windowsに登録したdistribution名である。

```powershell
wsl.exe --terminate 'NixOS'
wsl.exe --distribution 'NixOS'
```

inputやpackageを更新すると、MCP frontやcontainerを含むserviceがactivationで再起動することがある。
別のsessionが作業中なら、planと検査までを先に済ませ、適用はその作業が終わってから実行する。

## Inputの更新

NixOS、WSL、Home Managerのstable branchを維持したまま、checkoutのrootで更新する。

```sh
nix flake update nixpkgs nixos-wsl home-manager sops-nix
```

`architectureStandard`は上の`dotfiles-rebuild`が更新するため、この手順に含めない。

devenvとactrunは、`flake.nix`の公式release commitを差し替えた後に`nix flake lock`でupstreamの依存を固定する。
hostのnixpkgsには追従させず、host全体のchannelを変えずに各公式packageのcompilerと依存を使う。
devenvの公式packageはimport-from-derivationを使うため、version評価にもそのderivationの取得またはbuildが必要となる。

NixOS-WSLの更新で既定の`wsl.extraBin`に追加されたcommandは、project側の追加から外す。
`wsl-extra-bin-contract`で各`/bin`の名前の一意性と、必須commandの実行可能性を確認する。

## Rollback

通常の入口から、system profileのcurrent generationより前の、残っている直前のgenerationを選ぶ。
番号に欠番があっても、そのgenerationを選び、currentより新しいgenerationは選ばない。

```sh
dotfiles-rebuild --rollback --plan
dotfiles-rebuild --rollback
```

rollbackは最新のstandardを取得せず、新しいflakeをbuildも評価もしない。
書き手の排他は適用と共有し、rollbackの実行中は適用も別のrollbackも始められない。
選んだgenerationのWSL metadataで再起動の分類を求め、`nixos-rebuild switch --no-reexec --rollback`へ委譲する。
適用後は、system profileが選んだgenerationを指していることを確かめ、指していなければ`activation-failed`として終了status 5にする。
前世代が残っていない場合、historyを読めない場合、metadataを判定できない場合は、switch前に終了status 2で止まる。
`--rollback --plan`は差分とplanだけを表示し、書き手の排他を取らず、profileを切り替えない。

rollbackが戻すのはsystem generationだけである。
結果にはsystem profileの指す先とgeneration番号、running system、採用したclientごとの配備先とその実体を表示する。
clientのbinaryはsystem generationとは別のstateであり、このcommandは戻さない。
表示するのは、rollbackの後に実際に組み合わさったsystem generationとclientの配備先であり、client profileまで戻したことの表示ではない。
sourceのcommit、CLIのlogin session、containerの永続data、Windowsの設定もrestoreしない。
復旧後はdoctorと実際の利用経路を確認し、次の通常rebuildで問題のsourceを再適用しないようにする。

## 失敗時の調査

候補の用意、検証、buildの失敗ではactivationを始めない。
activationの失敗ではprofile、running system、serviceが部分適用のことがあるため、前世代がactiveだと断定せず、状態を確認する。

```sh
readlink -f /nix/var/nix/profiles/system
readlink -f /run/current-system
nix profile history --profile /nix/var/nix/profiles/system
systemctl --failed
journalctl -b -p err
journalctl -u UNIT -n 30
```

調査した原因をsourceまたは対象service側で直し、source変更をcommitしてから再度`dotfiles-rebuild`を実行する。
変更したsourceをまだ適用せず、既存generationへ戻す場合は上のrollbackを使う。

取消または異常終了で残った候補は、次の走行が所有者の消えた作業用directoryとreceiptのない候補を片付ける。
ただし、supervisorが全子孫の終了を記録していない走行と、`unconfirmed`の印がある物は、所有者が消えていても片付けない。
親がSIGKILLされた走行は、supervisorが終了を記録した後の走行が片付ける。
子の終了を確認できなかった走行の物は、動いているprocessがないことを確かめてから、表示された`--discard ID`で解放する。
`--discard ID`は、そのIDの候補と、所有者のprocessが消えた作業用directoryを解放する。
実行中の走行の作業用directoryは解放しない。
保持中の候補は、次のplan、適用、`--discard ID`が解放する。
状態は`$XDG_STATE_HOME/dotfiles-wsl/rebuild`に置き、既定は`~/.local/state/dotfiles-wsl/rebuild`である。

## 入口を保つ

PATHの`nixos-rebuild`は拒否するwrapperであり、直接のrollbackも受け付けない。
通常の適用とrollbackは`dotfiles-rebuild`を使い、dirty検査、候補の照合、WSL判定を迂回しない。
初回構築だけは`workstation/activation/rebuild/impl/bootstrap.sh`を使う。

profileやserviceを変えずに復旧候補を調べるsmokeでは、cleanなcheckoutで`dotfiles-rebuild --rollback --plan`を使う。
通常の`--plan`は隔離したsourceでのbuildを伴うが、いずれのplanもactivationとWSL停止を実行しない。
稼働中の実機で、smokeのために通常の適用やrollbackを実行しない。

## 検証

挙動は`rebuild-entrypoint`と`rebuild-candidate`が、実際のGit repositoryと取消signalを使って確認する。
取消はsessionを離れた子孫の回収まで、実際のprocessで確認する。
終了を確認できない場合に作業用directoryと候補のrootを残し、後続のplanとprune、`--candidate`が解放も適用もしない動作は、実際のsupervisorの結果を未確認へ置き換える代役で確認する。
親のSIGKILLは、子孫が止まるまでpruneが待つ動作まで、実際のprocessで確認する。
`rebuild-concurrent-edits`は候補の用意中、planの表示中、commit hookの実行中に別の書き手がcheckoutを編集またはcommitする場合、`rebuild-concurrent-planners`は並行したplanが公開する場合、`rebuild-cancelled-plan`はplanの表示中の取消を、書き手を同じ段で動かして確認する。
Nix、`nixos-rebuild`、検証commandはfixtureの依存であり、toplevelはlockの内容から導く。
このため、候補と評価はlockが一致するときだけ同じpathになる。

